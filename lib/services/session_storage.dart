import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/device_profile.dart';
import 'database.dart';
import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';
import '../models/display_unit.dart';
import '../models/gap_list.dart';
import '../models/sample_slice.dart';
import 'session_data.dart';
import 'session_metadata.dart';

/// Each [SessionChunks] row holds a whole number of samples in the packed
/// chunk format (see [SessionChunkCodec], its one home). The owning
/// [Sessions] row carries all metadata (channel count, sample rate,
/// calibration, etc.).
class SessionStorage {
  /// Start a new streaming session. The returned [LiveSessionWriter] is fed
  /// sample slices via [LiveSessionWriter.appendData] as data arrives and is
  /// passed to [finalizeSession] when recording stops.
  ///
  /// Note: every session stores all [kAdcChannelCount]; [channelLabels]
  /// and [visibleChannels] are retained for display only. [deviceMetadata] is
  /// the connected device's identity (see [toSessionDeviceMetadata]), frozen
  /// for export.
  ///
  /// This is hub-agnostic by contract: the caller snapshots everything the
  /// live buffer would supply ([tare], [channelCalibration],
  /// [samplesPerSec], [sourceRingCapacity]), so the storage layer never
  /// imports the hub.
  static Future<LiveSessionWriter> startSession({
    required Float64List tare,
    required List<ChannelCalibration> channelCalibration,
    required int samplesPerSec,
    required int sourceRingCapacity,
    required String name,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
    required DisplayUnit displayUnit,
    required Map<String, Object?> deviceMetadata,
  }) async {
    // Snapshot the tare once; the same values are persisted below and used by
    // the writer's peak scan, so stored peaks, stored tares and playback can
    // never disagree even if the user re-tares mid-recording.
    final tareSnapshot = Float64List.fromList(tare);

    final sessionId = await AppDatabase.instance.createSession(
      name: name,
      sampleRate: samplesPerSec,
      // We always persist every ADC channel, so the stored channel count must
      // match what the writer packs (and what loadSession reads back).
      channelCount: kAdcChannelCount,
      channelLabels: jsonEncode(channelLabels),
      tares: jsonEncode(tareSnapshot.toList()),
      // Snapshot the per-channel calibration in effect now; playback
      // converts through it even if calibration changes later.
      calibrationJson: jsonEncode([
        for (int ch = 0; ch < kAdcChannelCount; ch++)
          channelCalibration[ch].toJson(),
      ]),
      visibleChannels: jsonEncode(visibleChannels),
      // Frozen as the CSV export's default converted unit
      // (docs/csv-format-v1.md's recording-time snapshot requirement).
      displayUnit: displayUnit.name,
      deviceInfoJson: jsonEncode(deviceMetadata),
    );

    return LiveSessionWriter(
      sessionId,
      tareSnapshot,
      samplesPerSec,
      sourceRingCapacity: sourceRingCapacity,
    );
  }

  /// Discard a session that was created but never latched by its caller
  /// (e.g. the link dropped while its row was being inserted — see
  /// `RecordingController.startSession`). The writer has written no chunks,
  /// so this is a plain row delete, not a recovery case.
  static Future<void> discardSession(LiveSessionWriter writer) =>
      AppDatabase.instance.deleteSession(writer.sessionId);

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
      peaksRaw: writer.peaksRaw,
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
    required List<double> peaksRaw,
    required String gapsJson,
  }) {
    return AppDatabase.instance.completeSession(
      sessionId,
      sampleCount: sampleCount,
      durationMs: (sampleCount * 1000) ~/ sampleRate,
      // A channel that captured no samples leaves its peak at -infinity;
      // that must not reach the DB.
      peaksRaw: jsonEncode([for (final p in peaksRaw) p.isFinite ? p : 0.0]),
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
        peaksRaw: agg.peaksRaw,
        gapsJson: session.gaps,
      );
    }
  }

  /// Read a session's recorded data back from its chunks.
  ///
  /// TODO(perf): this materializes every chunk blob AND the full
  /// deinterleaved channel arrays (~2x session size transiently — a 1-hour
  /// session is ~58 MB of samples). If long sessions become common, stream
  /// the deinterleave (and consider isolating the [SessionData] stats scan,
  /// which currently runs eagerly on the UI thread below).
  static Future<SessionData?> loadSession(int sessionId) async {
    final row = await AppDatabase.instance.sessionById(sessionId);
    if (row == null) {
      throw StateError('loadSession: no session row with id $sessionId');
    }
    final session = row;
    final chunks = await AppDatabase.instance.sessionChunkData(session.id);

    if (chunks.isEmpty) {
      debugPrint('No chunks found for session: ${session.id}');
      return null;
    }

    final channelCount = session.channelCount;
    final sampleCount = session.sampleCount;
    final channels = List.generate(channelCount, (_) => Int32List(sampleCount));
    final codec = SessionChunkCodec(channelCount);

    int globalS = 0;
    for (final chunk in chunks) {
      // Frames beyond the metadata's sampleCount are silently truncated
      // (chunk/metadata disagreement is not surfaced today).
      codec.decode(chunk, (s, ch, raw) {
        final g = globalS + s;
        if (g < sampleCount) channels[ch][g] = raw;
      });
      globalS += codec.framesOf(chunk);
      if (globalS >= sampleCount) break;
    }

    return SessionData(
      channels: channels,
      sampleRate: session.sampleRate,
      sampleCount: globalS,
      calibrations: _parseCalibrations(session.calibrationJson, channelCount),
      tares: _parseTares(session.tares, channelCount),
      gaps: GapList.fromJson(session.gaps),
      ssnOrigin: session.ssnOrigin,
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

  /// Parse the JSON-encoded per-channel calibration snapshots stored on a
  /// [Session] row. Missing or malformed entries fall back to a nominal
  /// board with no load cell (electrical units only).
  static List<ChannelCalibration> _parseCalibrations(
    String json,
    int channelCount,
  ) => parseJsonColumn(
    json,
    channelCount,
    convert: (e) =>
        ChannelCalibration.fromJson(Map<String, dynamic>.from(e as Map)),
    fallback: (_) => ChannelCalibration(board: ChannelBoardCalibration()),
  );
}

/// Scans interleaved int32 chunk bytes, accumulating sample count and the
/// per-channel tare-adjusted peaks. Shared by the live writer and the
/// recovery path so the two can never compute peaks differently.
class _ChunkAggregate {
  _ChunkAggregate(this.channelCount);

  final int channelCount;
  int samples = 0;

  /// Per-channel maxima of (raw - tare). Starts at -infinity so the first
  /// real sample always replaces it; a never-positive channel must report
  /// its (negative) true max, not 0. Callers persisting this must guard the
  /// no-samples case (see [SessionStorage._completeSession]).
  late final List<double> peaksRaw = List.filled(
    channelCount,
    double.negativeInfinity,
  );

  void scan(Uint8List bytes, Float64List tare) {
    final codec = SessionChunkCodec(channelCount);
    samples += codec.framesOf(bytes);
    codec.decode(bytes, (_, ch, raw) {
      final val = raw - (ch < tare.length ? tare[ch] : 0);
      if (ch < peaksRaw.length && val > peaksRaw[ch]) {
        peaksRaw[ch] = val.toDouble();
      }
    });
  }
}

/// The one home of the packed chunk format: interleaved int32 LE values
/// `[ch0_s0, ch1_s0, ..., ch0_s1, ch1_s1, ...]`, [channelCount] values per
/// sample frame. Live writes ([LiveSessionWriter.appendData]), session loads
/// ([SessionStorage.loadSession]) and aggregate scans ([_ChunkAggregate])
/// share this so the layout, endianness and frame math can't drift apart.
class SessionChunkCodec {
  const SessionChunkCodec(this.channelCount);

  final int channelCount;

  /// Whole sample frames in [bytes] (trailing partial bytes are ignored).
  int framesOf(Uint8List bytes) => bytes.lengthInBytes ~/ (channelCount * 4);

  /// Pack [frames] samples as sample-major little-endian int32 bytes (the
  /// chunk format [decode] reads back), pulling each value from [valueAt].
  Uint8List pack(int frames, int Function(int sample, int channel) valueAt) {
    final out = ByteData(frames * channelCount * 4);
    int offset = 0;
    for (int s = 0; s < frames; s++) {
      for (int ch = 0; ch < channelCount; ch++) {
        out.setInt32(offset, valueAt(s, ch), Endian.little);
        offset += 4;
      }
    }
    return out.buffer.asUint8List();
  }

  /// Invoke [visit] once per value, in packed order (sample-major).
  void decode(
    Uint8List bytes,
    void Function(int sample, int channel, int raw) visit,
  ) {
    final data = ByteData.sublistView(bytes);
    final frames = framesOf(bytes);
    int offset = 0;
    for (int s = 0; s < frames; s++) {
      for (int ch = 0; ch < channelCount; ch++) {
        visit(s, ch, data.getInt32(offset, Endian.little));
        offset += 4;
      }
    }
  }
}

/// Streams recorded samples to the DB as they arrive, flushing in chunks so a
/// session can outlive the in-memory ring buffer and survive a crash.
///
/// All DB writes are serialized through [_writeQueue] so concurrent (unawaited)
/// [appendData] calls and the finalizing [flush] cannot interleave or reorder
/// chunks. The queue serializes ONLY the writes: each [SampleSlice] arrives
/// fully snapshotted at call time (see `DataHub.snapshotRange`), so a stalled
/// queue never observes ring slots the producer has since overwritten. If
/// storage falls a full ring behind, an error is latched (see [appendData])
/// so the backlog — and its memory — stops growing and the failure is
/// surfaced instead of recording into the void.
class LiveSessionWriter {
  LiveSessionWriter(
    this.sessionId,
    this.tare,
    this.sampleRate, {
    required this.sourceRingCapacity,
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

  /// Capacity (samples) of the producer's ring — the backlog bound for the
  /// backpressure latch in [appendData]. Supplied by the caller (the hub's
  /// `maxDataSz`); not read from the hub here.
  final int sourceRingCapacity;

  /// Samples accepted by [appendData] but not yet written by the serialized
  /// queue. Decrementing happens in the queued op's finally, so a wedged
  /// sink grows the count unboundedly — detecting that is the latch's job.
  int _unflushedSamples = 0;

  int _chunkIndex = 0;
  int totalSamplesRecorded = 0;

  /// Per-channel tare-adjusted peaks accumulated so far (see
  /// [_ChunkAggregate.peaksRaw]); read by [SessionStorage.finalizeSession].
  List<double> get peaksRaw => _agg.peaksRaw;

  /// Dropped-sample ranges accumulated across the recording, relative to the
  /// session's first sample. Persisted to the session row on every chunk
  /// flush (so a crash keeps the info up to the last flush) and once more in
  /// full by [SessionStorage.finalizeSession].
  final GapList gaps = GapList();

  /// Hub-absolute index of the session's first sample; latched on the first
  /// [appendData] call and used to make [gaps] session-relative.
  int? _originIdx;

  /// Device sample-counter value at the session's first sample (the
  /// dynamite-csv `ssn_origin`), latched alongside [_originIdx] from the
  /// hub's packet-counter anchor (see `DataHub.notePacketCounter`) and persisted
  /// to the session row in the same breath (see [_persistSsnOrigin]).
  /// Sessions start on a packet boundary (the decoder's continuity reset at
  /// recording start suppresses gap injection for the first recorded
  /// packet), so the index difference below is zero in practice; the formula
  /// keeps the latch correct even if that ever changes. Null until the first
  /// append.
  int? get ssnOrigin => _ssnOrigin;
  int? _ssnOrigin;

  /// Accumulates sample count and peak; shared scan logic with recovery.
  final _ChunkAggregate _agg = _ChunkAggregate(kAdcChannelCount);

  /// First write failure encountered, if any. Once set it stays set.
  Object? writeError;
  bool get hasError => writeError != null;

  final BytesBuilder _staging = BytesBuilder(copy: false);

  /// Serializes all DB writes. Each enqueued op awaits the previous one.
  Future<void> _writeQueue = Future.value();

  /// Test seam: when set, a flush's DB side effects (chunk insert + gap-range
  /// update) go here instead of the real database, so tests can stall and
  /// observe writes without opening one. Resolved lazily so constructing a
  /// writer never touches the database singleton. (The ssn-origin persist
  /// does NOT route through here — it fires once at latch time, so tests
  /// install an in-memory database for it.)
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

  /// Append a fully snapshotted slice of fresh samples (see
  /// `DataHub.snapshotRange`). Returns when this slice has been buffered
  /// (and flushed, if the threshold was crossed). Safe to call without
  /// awaiting; calls are serialized.
  Future<void> appendData(SampleSlice slice) {
    // Capture this slice's gap ranges synchronously, rebased to
    // session-relative indices.
    final int origin = _originIdx ??= slice.startIndex;
    if (_ssnOrigin == null) {
      final anchor = slice.anchor;
      _ssnOrigin = (anchor?.counter ?? 0) + (origin - (anchor?.hubIndex ?? 0));
      unawaited(_enqueue(_persistSsnOrigin));
    }
    for (final (s, e) in slice.gapRanges) {
      gaps.append(s - origin, e - origin);
    }

    final count = slice.sampleCount;
    _unflushedSamples += count;
    // Backpressure latch: once the accepted-but-unwritten backlog exceeds the
    // source ring's capacity, storage is a full ring behind the producer and
    // the backlog only grows (~16 KB/s) into a possibly wedged sink. Latch
    // an error so the session auto-stops loudly via the existing hasError
    // path. Checked at accept time — it trips even if the write queue never
    // runs again.
    if (writeError == null && _unflushedSamples > sourceRingCapacity) {
      writeError = StateError(
        'Storage fell more than the ring capacity ($sourceRingCapacity '
        'samples) behind the live stream; aborting recording',
      );
      debugPrint(
        'Session storage backpressure tripped (session $sessionId): '
        '$writeError',
      );
    }

    // Snapshot the sample slice before enqueueing.
    const codec = SessionChunkCodec(kAdcChannelCount);
    final bytes = codec.pack(count, (s, ch) => slice.channels[ch][s]);

    return _enqueue(() async {
      try {
        if (writeError != null) return;

        // Update peaks/sample-count via the same scan logic recovery uses.
        _agg.scan(bytes, tare);
        totalSamplesRecorded = _agg.samples;

        _staging.add(bytes);

        if (_staging.length >= _flushThreshold) {
          await _flushStaging();
        }
      } finally {
        _unflushedSamples -= count;
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

  /// Persist the latched [ssnOrigin] to the session row. Runs exactly once,
  /// enqueued at latch time, so it lands ahead of every chunk flush — a
  /// crash before the first flush still recovers the origin (chunk bytes
  /// can't reconstruct it). A failure latches [writeError], same as a failed
  /// flush.
  Future<void> _persistSsnOrigin() async {
    try {
      await AppDatabase.instance.setSessionSsnOrigin(sessionId, _ssnOrigin!);
    } catch (e) {
      writeError ??= e;
      debugPrint('Session ssn-origin persist failed (session $sessionId): $e');
    }
  }

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
