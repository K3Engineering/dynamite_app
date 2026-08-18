import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'database.dart';
import '../models/device_profile.dart';
import '../models/gap_list.dart';
import '../models/sample_slice.dart';

/// The one home of the packed chunk format: interleaved int32 LE values
/// `[ch0_s0, ch1_s0, ..., ch0_s1, ch1_s1, ...]`, [channelCount] values per
/// sample frame. Live writes ([LiveSessionWriter.appendData]), session loads
/// ([`SessionStorage.loadSession`]) and crash recovery's frame counting
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
    this.header, {
    required this.sourceRingCapacity,
    @visibleForTesting
    Future<int> Function(
      int? sessionId,
      int chunkIndex,
      Uint8List data,
      String gapsJson,
    )?
    chunkSink,
  }) : _chunkSink = chunkSink;

  /// The session-row metadata snapshotted at recording start (see
  /// [SessionHeader]), carried until the first chunk flush creates the row.
  final SessionHeader header;

  /// The session row's id, latched from the first chunk flush's row-creation
  /// transaction. Null until data exists — the row itself doesn't exist
  /// before that either (no row without data).
  int? get sessionId => _sessionId;
  int? _sessionId;

  /// The rate persisted on the session row at recording start, kept here so
  /// finalization math uses the same value the row carries.
  int get sampleRate => header.sampleRate;

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

  /// Dropped-sample ranges accumulated across the recording, relative to the
  /// session's first sample. Persisted to the session row on every chunk
  /// flush (so a crash keeps the info up to the last flush) and once more in
  /// full by `SessionStorage.finalizeSession`.
  final GapList gaps = GapList();

  /// Hub-absolute index of the session's first sample; latched on the first
  /// [appendData] call and used to make [gaps] session-relative.
  int? _originIdx;

  /// Device sample-counter value at the session's first sample (the
  /// dynamite-csv `ssn_origin`), latched alongside [_originIdx] from the
  /// hub's packet-counter anchor (see `DataHub.notePacketCounter`) and
  /// written into the session row when the first chunk flush creates it;
  /// chunk bytes alone can't reconstruct it, so it must be held until then.
  /// Sessions start on a packet boundary (the decoder's continuity reset at
  /// recording start suppresses gap injection for the first recorded
  /// packet), so the index difference below is zero in practice; the formula
  /// keeps the latch correct even if that ever changes. Null until the first
  /// append.
  int? get ssnOrigin => _ssnOrigin;
  int? _ssnOrigin;

  /// First write failure encountered, if any. Once set it stays set.
  Object? writeError;
  bool get hasError => writeError != null;

  final BytesBuilder _staging = BytesBuilder(copy: false);

  /// Serializes all DB writes. Each enqueued op awaits the previous one.
  Future<void> _writeQueue = Future.value();

  /// Test seam: when set, a flush's DB side effects go here instead of the
  /// real database, so tests can stall and observe writes without opening
  /// one. Null [sessionId] marks the first flush — the one that must return
  /// the session row's id (the production sink creates the row; a test seam
  /// may invent any id). Resolved lazily so constructing a writer never
  /// touches the database singleton.
  final Future<int> Function(
    int? sessionId,
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
      // Latched now, written when the first chunk flush creates the row.
      _ssnOrigin = (anchor?.counter ?? 0) + (origin - (anchor?.hubIndex ?? 0));
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
        'Session storage backpressure tripped (session $_sessionId): '
        '$writeError',
      );
    }

    // Snapshot the sample slice before enqueueing.
    const codec = SessionChunkCodec(kAdcChannelCount);
    final bytes = codec.pack(count, (s, ch) => slice.channels[ch][s]);

    return _enqueue(() async {
      try {
        if (writeError != null) return;

        totalSamplesRecorded += codec.framesOf(bytes);

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
      _sessionId ??= await (_chunkSink ?? _defaultSink)(
        _sessionId,
        chunkIdx,
        dataToSave,
        gapsJson,
      );
    } catch (e) {
      // Latch the first failure; stop accumulating so we don't grow unbounded
      // after the sink has gone away (e.g. disk full / web quota exceeded).
      writeError ??= e;
      debugPrint('Session chunk write failed (session $_sessionId): $e');
    }
  }

  /// The production sink: the first flush creates the session row (header
  /// metadata, the latched ssn origin, the gaps accrued so far) in the same
  /// transaction as the chunk; later flushes append chunks and keep the
  /// row's gap ranges current. Returns the session id for the latch.
  Future<int> _defaultSink(
    int? sessionId,
    int chunkIndex,
    Uint8List data,
    String gapsJson,
  ) async {
    if (sessionId == null) {
      // The ssn origin always precedes the first flush: appendData latches
      // it synchronously before any chunk bytes can exist.
      return AppDatabase.instance.createSessionWithFirstChunk(
        header: header,
        ssnOrigin: _ssnOrigin!,
        gaps: gapsJson,
        data: data,
      );
    }
    await AppDatabase.instance.insertChunk(sessionId, chunkIndex, data);
    await AppDatabase.instance.setSessionGaps(sessionId, gapsJson);
    return sessionId;
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
