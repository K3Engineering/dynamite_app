import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'database.dart';
import 'data_hub.dart';
import '../models/bucket_series.dart';
import '../models/gap_list.dart';
import '../models/graph_data_source.dart';

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
      visibleChannels: jsonEncode(visibleChannels),
    );

    return LiveSessionWriter(sessionId, tare, DataHub.samplesPerSec);
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

    await _completeSession(
      sessionId: writer.sessionId,
      sampleCount: writer.totalSamplesRecorded,
      sampleRate: writer.sampleRate,
      peakRaw: writer.peakRaw,
      gapsJson: writer.gaps.toJson(),
    );

    return writer.writeError;
  }

  /// Write a finished (or recovered) session's aggregates to its row and mark
  /// it completed. Shared by [finalizeSession] and [recoverIncompleteSessions]
  /// so both paths apply identical guards and duration math.
  static Future<void> _completeSession({
    required int sessionId,
    required int sampleCount,
    required int sampleRate,
    required double peakRaw,
    required String gapsJson,
  }) {
    return AppDatabase.instance.completeSession(
      sessionId,
      sampleCount: sampleCount,
      durationMs: (sampleCount * 1000) ~/ sampleRate,
      // A session that captured no samples leaves peakRaw at -infinity; that
      // must not reach the DB (or the session list's peak display).
      peakForceRaw: peakRaw.isFinite ? peakRaw : 0.0,
      gaps: gapsJson,
    );
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

      // Preserve the gaps persisted incrementally by the live writer (chunk
      // bytes alone can't reconstruct them).
      await _completeSession(
        sessionId: session.id,
        sampleCount: agg.samples,
        // Recovery uses the rate persisted on the row (finalize uses the
        // writer's, which is the same value from recording start) so a future
        // configurable rate can't skew reconstructed durations.
        sampleRate: session.sampleRate,
        peakRaw: agg.peakRaw,
        gapsJson: session.gaps,
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
      tares: _parseTares(session.tares, channelCount),
      gaps: GapList.fromJson(session.gaps),
    );
  }

  /// Parse the JSON-encoded per-channel tares stored on a [Session] row.
  /// Missing or malformed entries fall back to zero.
  static Float64List _parseTares(String json, int channelCount) =>
      Float64List.fromList(
        parseJsonColumn(
          json,
          channelCount,
          convert: (e) => (e as num).toDouble(),
          fallback: (_) => 0.0,
        ),
      );
}

/// Parse a JSON-encoded list column into exactly [count] entries: entry i is
/// [convert] applied to the i-th decoded element, or [fallback] when the
/// document is malformed, shorter than [count], or the element fails to
/// convert. Session metadata columns (tares, channel labels, visible
/// channels) are display-only, so a corrupt value degrades to defaults
/// instead of throwing.
List<T> parseJsonColumn<T>(
  String json,
  int count, {
  required T Function(Object? decoded) convert,
  required T Function(int index) fallback,
}) {
  List<dynamic>? parsed;
  try {
    final decoded = jsonDecode(json);
    if (decoded is List) parsed = decoded;
  } catch (e) {
    debugPrint('Failed to parse session metadata "$json": $e');
  }
  T entry(int i) {
    if (parsed == null || i >= parsed.length) return fallback(i);
    try {
      return convert(parsed[i]);
    } catch (_) {
      return fallback(i);
    }
  }

  return [for (int i = 0; i < count; i++) entry(i)];
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
        }
      }
    }
    samples += chunkSamples;
  }
}

/// Loaded session data for playback/review. An immutable data holder that
/// implements [GraphDataSource] directly, so the graph components render it
/// without an adapter; [sampleRate], [calibrationSlope] and [gaps] already
/// satisfy their interface counterparts.
class SessionData implements GraphDataSource {
  final List<Int32List> channels;
  @override
  final int sampleRate;
  final int sampleCount;
  @override
  final double calibrationSlope;
  final List<double> tares;

  /// Dropped-sample ranges (session-relative). The channel data holds held
  /// values across these ranges, so stats/buckets need no exclusion logic;
  /// renderers use this to hatch and break the polyline, and CSV export
  /// blanks these rows. Empty for crash-recovered sessions (gap info lost).
  @override
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

  /// Duration in seconds.
  double get durationSeconds => sampleCount / sampleRate;

  // -- GraphDataSource --------------------------------------------------------

  @override
  int get totalSamples => sampleCount;

  @override
  int get bufferCapacity => sampleCount;

  @override
  int get oldestSample => 0;

  @override
  Listenable get repaint => kNeverRepaints;

  /// Session data is immutable after load; there is no "new stream".
  @override
  int get dataGeneration => 0;

  @override
  ChannelSeries channel(int channelIndex) => (
    data: channels[channelIndex],
    min: mins[channelIndex],
    max: maxs[channelIndex],
    tare: tares[channelIndex],
    buckets: valueBuckets[channelIndex].series,
  );

  @override
  BucketSeries? diffBucketsFor(int channelIndex) =>
      diffBuckets[channelIndex].series;
}

/// Streams recorded samples to the DB as they arrive, flushing in chunks so a
/// session can outlive the in-memory ring buffer and survive a crash.
///
/// All DB writes are serialized through [_writeQueue] so concurrent (unawaited)
/// [appendData] calls and the finalizing [flush] cannot interleave or reorder
/// chunks. The queue serializes ONLY the writes: [appendData] snapshots its
/// sample slice synchronously at call time, so a stalled queue can never
/// observe ring-buffer slots the producer has since overwritten. If storage
/// nonetheless falls a full ring behind, an error is latched (see
/// [appendData]) so the backlog — and its memory — stops growing and the
/// failure is surfaced instead of recording into the void.
///
/// The first write error is latched in [writeError] rather than thrown
/// into the void, so the caller can surface it.
class LiveSessionWriter {
  LiveSessionWriter(
    this.sessionId,
    this.tare,
    this.sampleRate, {
    @visibleForTesting
    Future<void> Function(
      int sessionId,
      int chunkIndex,
      Uint8List data,
      String gapsJson,
    )?
    chunkSink,
  }) : _chunkSink = chunkSink;

  final int sessionId;

  /// Tare snapshot taken at recording start. Identical to the values persisted
  /// in the session's `tares` column, so the peak computed here always matches
  /// what playback shows, regardless of later re-tares.
  final Float64List tare;

  /// The rate persisted on the session row at recording start, kept here so
  /// finalization math uses the same value the row carries.
  final int sampleRate;

  int _chunkIndex = 0;
  int totalSamplesRecorded = 0;
  double peakRaw = 0.0;

  /// Dropped-sample ranges accumulated across the recording, relative to the
  /// session's first sample. Persisted to the session row on every chunk
  /// flush (so a crash keeps the info up to the last flush) and once more in
  /// full by [SessionStorage.finalizeSession].
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

  /// Test seam: when set, a flush's DB side effects (chunk insert + gap-range
  /// update) go here instead of the real database, so tests can stall and
  /// observe writes without opening one. Resolved lazily so constructing a
  /// writer never touches the database singleton.
  final Future<void> Function(
    int sessionId,
    int chunkIndex,
    Uint8List data,
    String gapsJson,
  )?
  _chunkSink;

  /// Flush whenever the staging buffer reaches ~this many bytes
  /// (~1 s at 1 kHz, 4 ch, 4 B/value).
  static const int _flushThreshold = 16384;

  /// Append [count] samples starting at ring-buffer logical index [startIdx].
  /// Returns when this slice has been buffered (and flushed, if the threshold
  /// was crossed). Safe to call without awaiting; calls are serialized.
  ///
  /// The slice is copied out of the ring buffer SYNCHRONOUSLY: hub state is
  /// only guaranteed fresh at call time, and the enqueued op runs only after
  /// prior DB writes drain — by which point the producer may have advanced
  /// far enough to overwrite these slots. Snapshotting here makes the copy
  /// correct no matter how long the queue stalls; the queue then only
  /// serializes staging and the DB write.
  Future<void> appendData(DataHub dataHub, int startIdx, int count) {
    // Capture this slice's gap ranges synchronously, rebased to
    // session-relative indices.
    final int origin = _originIdx ??= startIdx;
    for (final (s, e) in dataHub.gaps.rangesIn(startIdx, startIdx + count)) {
      gaps.append(s - origin, e - origin);
    }

    // Snapshot the sample slice before enqueueing.
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

    return _enqueue(() async {
      if (writeError != null) return;
      // Backpressure latch: if storage has fallen a full ring behind, the
      // producer has overwritten this slice's slots (the snapshot above is
      // still correct, but the backlog of snapshots grows ~16 KB/s while the
      // stall lasts). Latch an error so the session auto-stops loudly via the
      // existing hasError path instead of leaking memory into a wedged sink.
      if (startIdx < dataHub.totalSamples - DataHub.maxDataSz) {
        writeError ??= StateError(
          'Storage fell more than the ring capacity (${DataHub.maxDataSz} '
          'samples) behind the live stream; aborting recording',
        );
        debugPrint(
          'Session storage backpressure tripped (session $sessionId): '
          '$writeError',
        );
        return;
      }

      // Update peak/sample-count via the same scan logic recovery uses.
      _agg.scan(bytes, tare);
      totalSamplesRecorded = _agg.samples;
      peakRaw = _agg.peakRaw;

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
    final gapsJson = gaps.toJson();
    try {
      await (_chunkSink ?? _defaultChunkSink)(
        sessionId,
        chunkIdx,
        dataToSave,
        gapsJson,
      );
    } catch (e) {
      // Latch the first failure; stop accumulating so we don't grow unbounded
      // after the sink has gone away (e.g. disk full / web quota exceeded).
      writeError ??= e;
      debugPrint('Session chunk write failed (session $sessionId): $e');
    }
  }

  /// The production sink: writes the chunk, then updates the session row's
  /// gap ranges so a crash mid-recording keeps the info up to this flush
  /// (crash recovery rebuilds aggregates from chunks but cannot reconstruct
  /// gaps from them). The gaps update is one small row write per flush.
  static Future<void> _defaultChunkSink(
    int sessionId,
    int chunkIndex,
    Uint8List data,
    String gapsJson,
  ) async {
    await AppDatabase.instance.insertChunk(sessionId, chunkIndex, data);
    await AppDatabase.instance.setSessionGaps(sessionId, gapsJson);
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
