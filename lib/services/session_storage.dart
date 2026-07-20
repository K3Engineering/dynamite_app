import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'database.dart';
import 'data_hub.dart';
import '../models/bucket_series.dart';
import '../models/gap_list.dart';

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
  /// Note: every session stores all [DataHub.numAdcChannels]; [channelLabels]
  /// and [visibleChannels] are retained for display only. [visibleChannels]
  /// seeds the session detail view's channel selection (usually the live
  /// view's current set); it can be changed per session afterwards.
  static Future<LiveSessionWriter> startSession({
    required DataHub dataHub,
    required String name,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
    String notes = '',
  }) async {
    // Snapshot the tare once; the same values are persisted below and used by
    // the writer's peak scan, so stored peaks, stored tares and playback can
    // never disagree even if the user re-tares mid-recording.
    final tare = Float64List.fromList(dataHub.tare);

    final sessionId = await AppDatabase.instance.createSession(
      name: name,
      sampleRate: DataHub.samplesPerSec,
      // We always persist every ADC channel, so the stored channel count must
      // match what the writer packs (and what loadSession reads back).
      channelCount: DataHub.numAdcChannels,
      channelLabels: jsonEncode(channelLabels),
      tares: jsonEncode(tare.toList()),
      calibrationSlope: dataHub.deviceCalibration.slope,
      calibrationOffset: dataHub.deviceCalibration.offset,
      notes: notes,
      visibleChannels: jsonEncode(visibleChannels),
    );

    return LiveSessionWriter(sessionId, tare);
  }

  /// Finalize a streaming session: flush any buffered samples, then record the
  /// aggregates the writer accumulated and mark the session completed.
  ///
  /// Returns the writer's latched write error (if any). When non-null, the
  /// session may be short/truncated; the caller should surface it.
  static Future<Object?> finalizeSession({
    required LiveSessionWriter writer,
  }) async {
    await writer.flush();

    await AppDatabase.instance.completeSession(
      writer.sessionId,
      sampleCount: writer.totalSamplesRecorded,
      durationMs: (writer.totalSamplesRecorded * 1000) ~/ DataHub.samplesPerSec,
      // A session that captured no samples leaves peakRaw at -infinity; that
      // must not reach the DB (or the session list's peak display).
      peakForceRaw: writer.peakRaw.isFinite ? writer.peakRaw : 0.0,
      peakForceChannel: writer.peakChannel,
      gaps: writer.gaps.toJson(),
    );

    return writer.writeError;
  }

  /// Recovers any sessions left incomplete (e.g. the app crashed mid-recording)
  /// by scanning their persisted chunks to rebuild aggregates and marking them
  /// completed. Sessions with no chunks are deleted.
  static Future<void> recoverIncompleteSessions() async {
    final incomplete = await AppDatabase.instance.incompleteSessions();

    for (final session in incomplete) {
      debugPrint('Recovering incomplete session: ${session.id}');

      final chunks = await AppDatabase.instance.sessionChunkData(session.id);

      if (chunks.isEmpty) {
        // Started but never wrote a chunk. Nothing to keep.
        await AppDatabase.instance.deleteSession(session.id);
        continue;
      }

      // Rebuild aggregates against the tare persisted at recording start, the
      // same one loadSession applies, so recovered peaks match playback.
      final agg = _ChunkAggregate(session.channelCount);
      final tare = _parseTares(session.tares, session.channelCount);
      for (final chunk in chunks) {
        agg.scan(chunk, tare);
      }

      await AppDatabase.instance.completeSession(
        session.id,
        sampleCount: agg.samples,
        durationMs: (agg.samples * 1000) ~/ session.sampleRate,
        peakForceRaw: agg.peakRaw,
        peakForceChannel: agg.peakChannel,
      );
    }
  }

  /// Read a session's recorded data back from its chunks.
  static Future<SessionData?> loadSession(Session session) async {
    final chunks = await AppDatabase.instance.sessionChunkData(session.id);

    if (chunks.isEmpty) {
      debugPrint('No chunks found for session: ${session.id}');
      return null;
    }

    final channelCount = session.channelCount;
    final sampleCount = session.sampleCount;
    final channels = List.generate(channelCount, (_) => Int32List(sampleCount));

    int globalS = 0;
    for (final chunk in chunks) {
      final data = ByteData.sublistView(chunk);
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
      tares: _parseTares(session.tares, channelCount),
      gaps: GapList.fromJson(session.gaps),
    );
  }

  /// Parse the JSON-encoded per-channel tares stored on a [Session] row.
  /// Missing or malformed entries fall back to zero.
  static Float64List _parseTares(String json, int channelCount) {
    final tares = Float64List(channelCount);
    try {
      final List<dynamic> parsed = jsonDecode(json);
      for (int i = 0; i < channelCount && i < parsed.length; i++) {
        tares[i] = (parsed[i] as num).toDouble();
      }
    } catch (e) {
      debugPrint('Failed to parse session tares "$json": $e');
    }
    return tares;
  }
}

/// Scans interleaved int32 chunk bytes, accumulating sample count and the
/// tare-adjusted peak. Shared by the live writer and the recovery path so the
/// two can never compute peaks differently.
class _ChunkAggregate {
  _ChunkAggregate(this.channelCount);

  final int channelCount;
  int samples = 0;

  /// Starts at -infinity so the first real sample always replaces it; a
  /// never-positive stream must report its (negative) true max, not 0.
  /// Callers persisting this must guard the no-samples case (see
  /// [SessionStorage.finalizeSession]).
  double peakRaw = double.negativeInfinity;
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
  final List<double> tares;

  /// Dropped-sample ranges (session-relative). The channel data holds held
  /// values across these ranges, so stats/buckets need no exclusion logic;
  /// renderers use this to hatch and break the polyline, and CSV export
  /// blanks these rows. Empty for crash-recovered sessions (gap info lost).
  final GapList gaps;

  /// Per-channel extremes, computed once on construction.
  final List<double> mins;
  final List<double> maxs;

  /// Per-channel bucket aggregates over [bucketSize]-sample windows of the
  /// raw values. Mirrors DataHub's live buckets (same [BucketAccumulator])
  /// so the graphs can downsample cheaply. Gap samples hold the previous
  /// real value, so buckets are always fully populated and need no
  /// missing-data handling.
  final int bucketSize = 100;
  late final List<BucketAccumulator> valueBuckets;

  /// Per-channel bucket aggregates of the first-difference series
  /// (`diff[i] = raw[i] - raw[i-1]`), same bucket grid. Used by the
  /// derivative graph's bucket fast path; the gap/first-sample diff rule
  /// lives in [ingestDiff], mirroring DataHub's live ingest.
  late final List<BucketAccumulator> diffBuckets;

  SessionData({
    required this.channels,
    required this.sampleRate,
    required this.sampleCount,
    required this.calibrationSlope,
    required this.calibrationOffset,
    required this.tares,
    GapList? gaps,
  }) : gaps = gaps ?? GapList(),
       mins = List.filled(channels.length, 0.0),
       maxs = List.filled(channels.length, 0.0) {
    final int numBuckets = (sampleCount == 0)
        ? 0
        : ((sampleCount - 1) ~/ bucketSize) + 1;
    valueBuckets = List.generate(
      channels.length,
      (_) => BucketAccumulator(bucketSize: bucketSize, numBuckets: numBuckets),
    );
    diffBuckets = List.generate(
      channels.length,
      (_) => BucketAccumulator(bucketSize: bucketSize, numBuckets: numBuckets),
    );

    for (int ch = 0; ch < channels.length; ch++) {
      if (sampleCount == 0) continue;
      double mn = double.infinity;
      double mx = double.negativeInfinity;

      for (int i = 0; i < sampleCount; i++) {
        final v = channels[ch][i];
        if (v < mn) mn = v.toDouble();
        if (v > mx) mx = v.toDouble();

        final int diff = ingestDiff(
          sampleIndex: i,
          value: v,
          prevValue: i > 0 ? channels[ch][i - 1] : 0,
          gaps: this.gaps,
        );

        valueBuckets[ch].add(i, v);
        diffBuckets[ch].add(i, diff);
      }
      mins[ch] = mn;
      maxs[ch] = mx;
    }
  }

  /// Get peak raw value for a given channel. Seeded from the first sample so
  /// a never-positive channel reports its true (negative) max, not 0.
  int peakRaw(int ch) {
    final data = channels[ch];
    if (sampleCount == 0) return 0;
    int peak = data[0];
    for (int i = 1; i < sampleCount; i++) {
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
  LiveSessionWriter(this.sessionId, this.tare);

  final int sessionId;

  /// Tare snapshot taken at recording start. Identical to the values persisted
  /// in the session's `tares` column, so the peak computed here always matches
  /// what playback shows, regardless of later re-tares.
  final Float64List tare;

  int _chunkIndex = 0;
  int totalSamplesRecorded = 0;
  double peakRaw = 0.0;
  int peakChannel = 0;

  /// Dropped-sample ranges accumulated across the recording, relative to the
  /// session's first sample. Persisted by [SessionStorage.finalizeSession].
  final GapList gaps = GapList();

  /// Hub-absolute index of the session's first sample; latched on the first
  /// [appendData] call and used to make [gaps] session-relative.
  int? _originIdx;

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
    // Capture this slice's gap ranges synchronously (hub state is only
    // guaranteed fresh at call time), rebased to session-relative indices.
    final int origin = _originIdx ??= startIdx;
    for (final (s, e) in dataHub.gaps.rangesIn(startIdx, startIdx + count)) {
      gaps.append(s - origin, e - origin);
    }
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
      _agg.scan(bytes, tare);
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
      await AppDatabase.instance.insertChunk(sessionId, chunkIdx, dataToSave);
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
