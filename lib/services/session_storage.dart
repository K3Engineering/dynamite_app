import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'database.dart';
import 'bt_handling.dart';

/// Chunk format: packed int32 LE values, interleaved
/// `[ch0_s0, ch1_s0, ..., ch0_s1, ch1_s1, ...]`, with one value per ADC channel
/// ([DataHub.numAdcChannels]) per sample. Each [SessionChunks] row holds a
/// whole number of samples. The owning [Sessions] row carries all metadata
/// (channel count, sample rate, calibration, etc.).
class SessionStorage {
  /// Start a new streaming session. The returned [LiveSessionWriter] is fed
  /// sample slices via [LiveSessionWriter.appendData] as data arrives and is
  /// passed to [finalizeSession] when recording stops.
  ///
  /// Note: every session stores all [DataHub.numAdcChannels]; [channelCount]
  /// and [channelLabels] are retained for display only.
  static Future<LiveSessionWriter> startSession({
    required DataHub dataHub,
    required String name,
    required List<String> channelLabels,
    required int channelCount,
    String notes = '',
  }) async {
    final sessionId = await AppDatabase.instance.insertSession(
      SessionsCompanion.insert(
        name: Value(name),
        createdAt: DateTime.now(),
        sampleRate: const Value(DataHub.samplesPerSec),
        // We always persist every ADC channel, so the stored channel count must
        // match what the writer packs (and what loadSession reads back).
        channelCount: const Value(DataHub.numAdcChannels),
        channelLabels: Value(jsonEncode(channelLabels)),
        calibrationSlope: Value(dataHub.deviceCalibration.slope),
        calibrationOffset: Value(dataHub.deviceCalibration.offset),
        notes: Value(notes),
        isCompleted: const Value(false),
      ),
    );

    return LiveSessionWriter(sessionId);
  }

  /// Finalize a streaming session: flush any buffered samples, then record the
  /// aggregates the writer accumulated and mark the session completed.
  ///
  /// Returns the writer's latched write error (if any). When non-null, the
  /// session may be short/truncated; the caller should surface it.
  static Future<Object?> finalizeSession({
    required LiveSessionWriter writer,
    required DataHub dataHub,
  }) async {
    await writer.flush();

    await AppDatabase.instance.updateSession(
      writer.sessionId,
      SessionsCompanion(
        sampleCount: Value(writer.totalSamplesRecorded),
        durationMs: Value(
          (writer.totalSamplesRecorded * 1000) ~/ DataHub.samplesPerSec,
        ),
        peakForceRaw: Value(writer.peakRaw),
        peakForceChannel: Value(writer.peakChannel),
        isCompleted: const Value(true),
      ),
    );

    return writer.writeError;
  }

  /// Recovers any sessions left incomplete (e.g. the app crashed mid-recording)
  /// by scanning their persisted chunks to rebuild aggregates and marking them
  /// completed. Sessions with no chunks are deleted.
  static Future<void> recoverIncompleteSessions() async {
    final incomplete = await (AppDatabase.instance.select(
      AppDatabase.instance.sessions,
    )..where((t) => t.isCompleted.equals(false))).get();

    for (final session in incomplete) {
      debugPrint('Recovering incomplete session: ${session.id}');

      final chunks = await (AppDatabase.instance.select(
        AppDatabase.instance.sessionChunks,
      )..where((t) => t.sessionId.equals(session.id))).get();

      if (chunks.isEmpty) {
        // Started but never wrote a chunk. Nothing to keep.
        await AppDatabase.instance.deleteSession(session.id);
        continue;
      }

      // The tare in effect at crash time isn't persisted, so recovered peaks
      // are best-effort (computed against a zero tare).
      final agg = _ChunkAggregate(session.channelCount);
      for (final chunk in chunks) {
        agg.scan(chunk.data, _zeroTare);
      }

      await AppDatabase.instance.updateSession(
        session.id,
        SessionsCompanion(
          sampleCount: Value(agg.samples),
          durationMs: Value((agg.samples * 1000) ~/ session.sampleRate),
          peakForceRaw: Value(agg.peakRaw),
          peakForceChannel: Value(agg.peakChannel),
          isCompleted: const Value(true),
        ),
      );
    }
  }

  /// Read a session's recorded data back from its chunks.
  static Future<SessionData?> loadSession(Session session) async {
    final chunks = await (AppDatabase.instance.select(
      AppDatabase.instance.sessionChunks,
    )..where((t) => t.sessionId.equals(session.id))
     ..orderBy([(t) => OrderingTerm(expression: t.chunkIndex)])).get();

    if (chunks.isEmpty) {
      debugPrint('No chunks found for session: ${session.id}');
      return null;
    }

    final channelCount = session.channelCount;
    final sampleCount = session.sampleCount;
    final channels = List.generate(channelCount, (_) => Int32List(sampleCount));

    int globalS = 0;
    for (final chunk in chunks) {
      final data = ByteData.sublistView(chunk.data);
      final chunkSamples = data.lengthInBytes ~/ (channelCount * 4);
      int offset = 0;
      for (int s = 0; s < chunkSamples; s++) {
        if (globalS >= sampleCount) break;
        for (int ch = 0; ch < channelCount; ch++) {
          channels[ch][globalS] = data.getInt32(offset, Endian.little);
          offset += 4;
        }
        globalS++;
      }
    }

    return SessionData(
      channels: channels,
      sampleRate: session.sampleRate,
      sampleCount: globalS,
      calibrationSlope: session.calibrationSlope,
      calibrationOffset: session.calibrationOffset,
    );
  }
}

/// Zero tare used when no tare is available (recovery path).
final Float64List _zeroTare = Float64List(DataHub.numAdcChannels);

/// Scans interleaved int32 chunk bytes, accumulating sample count and the
/// tare-adjusted peak. Shared by the live writer and the recovery path so the
/// two can never compute peaks differently.
class _ChunkAggregate {
  _ChunkAggregate(this.channelCount);

  final int channelCount;
  int samples = 0;
  double peakRaw = 0.0;
  int peakChannel = 0;

  void scan(Uint8List bytes, Float64List tare) {
    final data = ByteData.sublistView(bytes);
    final chunkSamples = data.lengthInBytes ~/ (channelCount * 4);
    int offset = 0;
    for (int s = 0; s < chunkSamples; s++) {
      for (int ch = 0; ch < channelCount; ch++) {
        final raw = data.getInt32(offset, Endian.little);
        offset += 4;
        final val = raw - (ch < tare.length ? tare[ch] : 0);
        if (val > peakRaw) {
          peakRaw = val.toDouble();
          peakChannel = ch;
        }
      }
    }
    samples += chunkSamples;
  }
}

/// Loaded session data for playback/review. A plain immutable data holder;
/// the UI wraps it in a GraphDataSource adapter for rendering.
class SessionData {
  final List<Int32List> channels;
  final int sampleRate;
  final int sampleCount;
  final double calibrationSlope;
  final int calibrationOffset;

  /// Per-channel extremes, computed once on construction.
  final List<double> mins;
  final List<double> maxs;

  /// Per-channel, per-bucket aggregates over [bucketSize]-sample windows.
  /// Mirrors DataHub's live buckets so the minimap can downsample cheaply.
  final int bucketSize = 100;
  late final List<Int32List> bucketMins;
  late final List<Int32List> bucketMaxs;
  late final List<Int32List> bucketSums;

  SessionData({
    required this.channels,
    required this.sampleRate,
    required this.sampleCount,
    required this.calibrationSlope,
    required this.calibrationOffset,
  })  : mins = List.filled(channels.length, 0.0),
        maxs = List.filled(channels.length, 0.0) {
    final int numBuckets =
        (sampleCount == 0) ? 0 : ((sampleCount - 1) ~/ bucketSize) + 1;
    bucketMins = List.generate(channels.length, (_) => Int32List(numBuckets));
    bucketMaxs = List.generate(channels.length, (_) => Int32List(numBuckets));
    bucketSums = List.generate(channels.length, (_) => Int32List(numBuckets));

    for (int ch = 0; ch < channels.length; ch++) {
      if (sampleCount == 0) continue;
      double mn = double.infinity;
      double mx = double.negativeInfinity;

      for (int i = 0; i < sampleCount; i++) {
        final v = channels[ch][i];
        if (v < mn) mn = v.toDouble();
        if (v > mx) mx = v.toDouble();

        final int bIdx = i ~/ bucketSize;
        final int sIdx = i % bucketSize;
        if (sIdx == 0) {
          bucketMins[ch][bIdx] = v;
          bucketMaxs[ch][bIdx] = v;
          bucketSums[ch][bIdx] = v;
        } else {
          if (v < bucketMins[ch][bIdx]) bucketMins[ch][bIdx] = v;
          if (v > bucketMaxs[ch][bIdx]) bucketMaxs[ch][bIdx] = v;
          bucketSums[ch][bIdx] += v;
        }
      }
      mins[ch] = mn;
      maxs[ch] = mx;
    }
  }

  /// Get peak raw value for a given channel.
  int peakRaw(int ch) {
    int peak = 0;
    final data = channels[ch];
    for (int i = 0; i < sampleCount; i++) {
      if (data[i] > peak) peak = data[i];
    }
    return peak;
  }

  /// Get average raw value for a given channel.
  double averageRaw(int ch) {
    double sum = 0;
    final data = channels[ch];
    for (int i = 0; i < sampleCount; i++) {
      sum += data[i];
    }
    return sum / sampleCount;
  }

  /// Duration in seconds.
  double get durationSeconds => sampleCount / sampleRate;
}

/// Streams recorded samples to the DB as they arrive, flushing in chunks so a
/// session can outlive the in-memory ring buffer and survive a crash.
///
/// All DB writes are serialized through [_writeQueue] so concurrent (unawaited)
/// [appendData] calls and the finalizing [flush] cannot interleave or reorder
/// chunks. The first write error is latched in [writeError] rather than thrown
/// into the void, so the caller can surface it.
class LiveSessionWriter {
  LiveSessionWriter(this.sessionId);

  final int sessionId;

  int _chunkIndex = 0;
  int totalSamplesRecorded = 0;
  double peakRaw = 0.0;
  int peakChannel = 0;

  /// Accumulates sample count and peak; shared scan logic with recovery.
  final _ChunkAggregate _agg = _ChunkAggregate(DataHub.numAdcChannels);

  /// First write failure encountered, if any. Once set it stays set.
  Object? writeError;
  bool get hasError => writeError != null;

  final BytesBuilder _staging = BytesBuilder(copy: false);

  /// Serializes all DB writes. Each enqueued op awaits the previous one.
  Future<void> _writeQueue = Future.value();

  /// Flush whenever the staging buffer reaches ~this many bytes
  /// (~2 s at 1 kHz, 2 ch, 4 B/value).
  static const int _flushThreshold = 16384;

  /// Append [count] samples starting at ring-buffer logical index [startIdx].
  /// Returns when this slice has been buffered (and flushed, if the threshold
  /// was crossed). Safe to call without awaiting; calls are serialized.
  Future<void> appendData(DataHub dataHub, int startIdx, int count) {
    return _enqueue(() async {
      if (writeError != null) return;
      const numLines = DataHub.numAdcChannels;
      final buffer = ByteData(count * numLines * 4);
      int offset = 0;
      for (int s = startIdx; s < startIdx + count; s++) {
        for (int ch = 0; ch < numLines; ch++) {
          buffer.setInt32(
            offset,
            dataHub.rawData[ch][s % DataHub.maxDataSz],
            Endian.little,
          );
          offset += 4;
        }
      }

      final bytes = buffer.buffer.asUint8List();
      // Update peak/sample-count via the same scan logic recovery uses.
      _agg.scan(bytes, dataHub.tare);
      totalSamplesRecorded = _agg.samples;
      peakRaw = _agg.peakRaw;
      peakChannel = _agg.peakChannel;

      _staging.add(bytes);

      if (_staging.length >= _flushThreshold) {
        await _flushStaging();
      }
    });
  }

  /// Flush any buffered samples to a chunk. Serialized with appends.
  Future<void> flush() => _enqueue(_flushStaging);

  /// Performs the actual chunk write. Must run inside [_enqueue].
  Future<void> _flushStaging() async {
    if (_staging.isEmpty || writeError != null) return;
    // takeBytes() clears the builder, so a concurrent append can't see it.
    final dataToSave = _staging.takeBytes();
    final chunkIdx = _chunkIndex++;
    try {
      await AppDatabase.instance
          .into(AppDatabase.instance.sessionChunks)
          .insert(
            SessionChunksCompanion.insert(
              sessionId: sessionId,
              chunkIndex: chunkIdx,
              data: dataToSave,
            ),
          );
    } catch (e) {
      // Latch the first failure; stop accumulating so we don't grow unbounded
      // after the sink has gone away (e.g. disk full / web quota exceeded).
      writeError ??= e;
      debugPrint('Session chunk write failed (session $sessionId): $e');
    }
  }

  /// Chain [op] after all previously enqueued writes and return its completion.
  Future<void> _enqueue(Future<void> Function() op) {
    final next = _writeQueue.then((_) => op());
    // Swallow errors on the queue itself so one failure doesn't poison the
    // chain; real failures are latched in [writeError].
    _writeQueue = next.catchError((_) {});
    return next;
  }
}
