import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';
import '../models/device_profile.dart';
import '../models/gap_list.dart';
import '../models/sample_slice.dart';
import 'session_journal.dart';
import 'session_store_backend.dart';

/// The session-directory files' names are declared in
/// session_store_backend.dart; this file is the codec's home.
class SessionChunkCodec {
  const SessionChunkCodec(this.channelCount);

  final int channelCount;

  /// The ADC is 24-bit: real sample values are confined to ±2^23, so int32
  /// values outside that range are reserved territory by construction —
  /// [gapSentinel] is its first occupant. Encode paths must never emit an
  /// out-of-range real value, and nothing may read the reserved range as
  /// ordinary data.
  static const int maxAdcValue = (1 << 23) - 1;
  static const int minAdcValue = -(1 << 23);

  /// The dropped-samples marker: a frame whose every channel reads
  /// [gapSentinel] is a gap. Held values are a representation, not a signal
  /// property (a statically-loaded cell legitimately repeats identical real
  /// values forever), so a gap must be marked in-band — runs of equal
  /// frames can never be post-hoc diagnosed as one.
  static const int gapSentinel = 0x7FFFFFFF;

  /// Byte length of one packed sample frame.
  int get frameBytes => channelCount * 4;

  /// Whole sample frames in [bytes]. Callers decide what trailing partial
  /// bytes mean; [decodeWithGaps] rejects them as a torn write.
  int framesOf(Uint8List bytes) => bytes.lengthInBytes ~/ frameBytes;

  /// Pack [frames] samples as sample-major little-endian int32 bytes (the
  /// chunk format [decodeWithGaps] reads back), pulling each value from
  /// [valueAt]. Real values only: [valueAt] returning anything outside the
  /// 24-bit ADC range (the sentinel's territory included) is an encoder bug
  /// and throws, so a misbehaving source can never fabricate a gap or
  /// smuggle a reserved value into the data stream.
  Uint8List pack(int frames, int Function(int sample, int channel) valueAt) {
    final out = ByteData(frames * channelCount * 4);
    int offset = 0;
    for (int s = 0; s < frames; s++) {
      for (int ch = 0; ch < channelCount; ch++) {
        final raw = valueAt(s, ch);
        if (raw < minAdcValue || raw > maxAdcValue) {
          throw ArgumentError.value(
            raw,
            'valueAt',
            'sample outside the 24-bit ADC range: encoder bug '
                '(sample $s, channel $ch)',
          );
        }
        out.setInt32(offset, raw, Endian.little);
        offset += 4;
      }
    }
    return out.buffer.asUint8List();
  }

  /// Bulk-mark the whole frames inside [gapRanges] (`[start, end)`,
  /// relative to the start of [bytes]) with the gap sentinel on every
  /// channel. The real (held) values were packed first; this overwrites
  /// them so the byte stream self-describes its gaps. Ranges must lie
  /// inside the buffer — an out-of-range range is a caller bug and throws.
  void fillGapSentinels(Uint8List bytes, Iterable<(int, int)> gapRanges) {
    final view = ByteData.sublistView(bytes);
    final frames = framesOf(bytes);
    for (final (start, end) in gapRanges) {
      if (start < 0 || end > frames || end <= start) {
        throw RangeError(
          'gap range [$start, $end) does not fit $frames frames',
        );
      }
      for (int s = start; s < end; s++) {
        for (int ch = 0; ch < channelCount; ch++) {
          view.setInt32(
            (s * channelCount + ch) * 4,
            gapSentinel,
            Endian.little,
          );
        }
      }
    }
  }

  /// Decode [bytes] into per-channel arrays, turning sentinel frames into a
  /// [GapList] and hold-filling the channel arrays with each channel's
  /// previous real value (the held-value representation the graphs, stats
  /// and exports already consume). [bytes] must be an exact multiple of
  /// [frameBytes] — a torn tail is a corrupt recording, not a shorter one.
  /// A gap frame is sentinel on ALL channels; a frame mixing sentinel and
  /// real values, a sentinel first frame (recording starts never open with
  /// a gap, so hold-fill has no predecessor), or a non-sentinel value
  /// outside the 24-bit ADC range are states the write path never produces
  /// and throw.
  ({List<Int32List> channels, GapList gaps}) decodeWithGaps(Uint8List bytes) {
    if (bytes.lengthInBytes % frameBytes != 0) {
      throw StateError(
        '${bytes.lengthInBytes} data bytes do not divide into whole '
        '$frameBytes-byte frames — a torn mid-frame write is damage, '
        'not a shorter recording',
      );
    }
    final view = ByteData.sublistView(bytes);
    final frames = framesOf(bytes);
    final channels = List.generate(channelCount, (_) => Int32List(frames));
    final gaps = GapList();
    for (int s = 0; s < frames; s++) {
      final base = s * channelCount * 4;
      bool isGap = false;
      for (int ch = 0; ch < channelCount; ch++) {
        final raw = view.getInt32(base + ch * 4, Endian.little);
        final hereGap = raw == gapSentinel;
        if (ch > 0 && hereGap != isGap) {
          throw StateError(
            'frame $s mixes sentinel and real channel values — '
            'the write path fills gap frames whole',
          );
        }
        isGap = hereGap;
        if (!isGap) {
          if (raw < minAdcValue || raw > maxAdcValue) {
            throw StateError(
              'frame $s channel $ch holds $raw, outside the 24-bit ADC '
              'range — the encoder never emits one, so this is a corrupt '
              'file, not a measurement',
            );
          }
          channels[ch][s] = raw;
        }
      }
      if (isGap) {
        if (s == 0) {
          throw StateError(
            'frame 0 is a gap frame — a session never starts mid-gap',
          );
        }
        gaps.append(s, s + 1);
        for (int ch = 0; ch < channelCount; ch++) {
          channels[ch][s] = channels[ch][s - 1];
        }
      }
    }
    return (channels: channels, gaps: gaps);
  }
}

/// The [SessionMeta] fields snapshotted at recording start and carried by
/// [LiveSessionWriter] until its first packet. ssnOrigin is the one journal
/// field the writer can't snapshot at start — it latches at the first
/// append, so the meta can only be stamped then (the journal's line 1 is
/// written WITH the first data append, not at start).
typedef SessionHeader = ({
  String name,
  int sampleRate,
  int channelCount,
  List<String> channelLabels,
  List<double?> tares,
  List<ChannelCalibration> calibration,
  List<bool> visibleChannels,
  String displayUnit,
  Map<String, Object?> deviceInfo,
  SessionBoardMeta? boardMeta,
  String recordedAt,
});

/// The journal's line 1 out of [header] plus the latched [ssnOrigin] —
/// recordedAt stays the recording-start clock even though the write happens
/// at the first packet.
SessionMeta sessionMetaFromHeader(SessionHeader header, int ssnOrigin) =>
    SessionMeta(
      name: header.name,
      sampleRate: header.sampleRate,
      channelCount: header.channelCount,
      channelLabels: header.channelLabels,
      tares: header.tares,
      calibration: header.calibration,
      visibleChannels: header.visibleChannels,
      displayUnit: header.displayUnit,
      deviceInfo: header.deviceInfo,
      boardMeta: header.boardMeta,
      recordedAt: header.recordedAt,
      ssnOrigin: ssnOrigin,
    );

/// Streams recorded samples to the session's data.raw as they arrive: one
/// serialized write per accepted packet, flushed individually, so a session
/// can outlive the in-memory ring buffer and a crash loses at most the
/// in-flight packet.
///
/// All writes are serialized through [_writeQueue] so concurrent (unawaited)
/// [appendData] calls and the finalizing [flush] cannot interleave or reorder
/// packets. The queue serializes ONLY the writes: each [SampleSlice] arrives
/// fully snapshotted at call time (see `DataHub.snapshotRange`), so a stalled
/// queue never observes ring slots the producer has since overwritten. If
/// storage falls a full ring behind, an error is latched (see [appendData])
/// so the backlog — and its memory — stops growing and the failure is
/// surfaced instead of recording into the void.
class LiveSessionWriter {
  LiveSessionWriter(
    this.header, {
    required this.sourceRingCapacity,
    required this.onWriteError,
    required SessionSinkFactory sinkFactory,
  }) : _sinkFactory = sinkFactory;

  /// The journal-line-1 fields snapshotted at recording start (see
  /// [SessionHeader]), carried until the first packet's write stamps them.
  final SessionHeader header;

  /// The session id (the directory's name), latched from the first write's
  /// created sink. Null until data exists — the directory itself doesn't
  /// exist before that either (no artifact without data). Outlives the open
  /// sink: [closeSink] releases the handle, not the session's identity.
  String? get sessionId => _sessionId;
  String? _sessionId;

  /// data.raw's byte length from the last acked append, or null when no
  /// append has ever succeeded. The finalize-time check compares this with
  /// the accepted-frames claim.
  int? get ackedDataLength => _ackedDataLength;
  int? _ackedDataLength;

  SessionDataSink? _sink;

  /// The rate stamped in the journal at creation, kept here so finalization
  /// math uses the same value.
  int get sampleRate => header.sampleRate;

  /// Capacity (samples) of the producer's ring — the backlog bound for the
  /// backpressure latch in [appendData]. Supplied by the caller (the hub's
  /// `maxDataSz`); not read from the hub here.
  final int sourceRingCapacity;

  /// Samples accepted by [appendData] but not yet written by the serialized
  /// queue. Decrementing happens in the queued op's finally, so a wedged
  /// sink grows the count unboundedly — detecting that is the latch's job.
  int _unflushedSamples = 0;

  /// Frames the queue has accepted for writing (successful or not) — the
  /// "accepted" side of the finalize check; the acked-length side is what's
  /// actually on disk.
  int totalSamplesRecorded = 0;

  /// Frames multiplied by the packed frame size — what [ackedDataLength]
  /// must equal at finalize when every accepted packet landed.
  int get expectedDataBytes =>
      totalSamplesRecorded *
      const SessionChunkCodec(kAdcChannelCount).frameBytes;

  /// Hub-absolute index of the session's first sample; latched on the first
  /// [appendData] call.
  int? _originIdx;

  /// Device sample-counter value at the session's first sample (the
  /// dynamite-csv `ssn_origin`), latched alongside [_originIdx] from the
  /// hub's packet-counter anchor (see `DataHub.notePacketCounter`) and
  /// stamped into the journal when the first packet's write creates the
  /// session — data bytes alone can't reconstruct it, so it must be held
  /// until then. Sessions start on a packet boundary (the decoder's
  /// continuity reset at recording start suppresses gap injection for the
  /// first recorded packet), so the index difference below is zero in
  /// practice; the formula keeps the latch correct even if that ever
  /// changes. Null until the first append.
  int? get ssnOrigin => _ssnOrigin;
  int? _ssnOrigin;

  /// First write failure encountered, if any. Once set it stays set.
  Object? writeError;
  bool get hasError => writeError != null;

  /// Called with the first failure the moment it latches (either latch
  /// point below): recording's auto-stop rides this rather than polling
  /// [hasError] on a later batch, so a failed last packet under an idle
  /// feed can't leave a session "recording" into the void until manual
  /// stop.
  final void Function(Object error) onWriteError;

  /// Latch [error] as the first failure (a later failure keeps the first
  /// as the cause) and notify [onWriteError] exactly once.
  void _latchError(Object error) {
    if (writeError != null) return;
    writeError = error;
    onWriteError.call(error);
  }

  /// Serializes all writes. Each enqueued op awaits the previous one.
  Future<void> _writeQueue = Future.value();

  /// Opens the session on the first write (dir + journal + first append,
  /// one flush) and hands back its sink. The production factory is the
  /// store's `createDataSink`; recording tests stall/observe via their own.
  final Future<SessionDataSink> Function(SessionMeta meta, Uint8List firstData)
  _sinkFactory;

  /// Append a fully snapshotted slice of fresh samples (see
  /// `DataHub.snapshotRange`). Returns when this slice has been written and
  /// flushed. Safe to call without awaiting; calls are serialized.
  Future<void> appendData(SampleSlice slice) {
    final int origin = _originIdx ??= slice.startIndex;
    if (_ssnOrigin == null) {
      // The decoder's packet-counter anchor is non-null at any append: a
      // recording can latch only on a flowing feed (StartSessionNoData), and
      // a flowing feed has seen packets. Null here means the guard was
      // bypassed — fabricating `0` would silently persist a wrong origin.
      final anchor = slice.anchor!;
      _ssnOrigin = anchor.counter + (origin - anchor.hubIndex);
    }

    final count = slice.sampleCount;
    _unflushedSamples += count;
    // Backpressure latch: once the accepted-but-unwritten backlog exceeds the
    // source ring's capacity, storage is a full ring behind the producer and
    // the backlog only grows into a possibly wedged sink. Latch an error so
    // the session auto-stops loudly via [onWriteError]. Checked at accept
    // time — it trips even if the write queue never runs again.
    if (writeError == null && _unflushedSamples > sourceRingCapacity) {
      final error = StateError(
        'Storage fell more than the ring capacity ($sourceRingCapacity '
        'samples) behind the live stream; aborting recording',
      );
      debugPrint(
        'Session storage backpressure tripped (session $sessionId): $error',
      );
      _latchError(error);
    }

    // Pack real values first, then mark the slice's gap frames in-band.
    const codec = SessionChunkCodec(kAdcChannelCount);
    final bytes = codec.pack(count, (s, ch) => slice.channels[ch][s]);
    final startIndex = slice.startIndex;
    codec.fillGapSentinels(bytes, [
      for (final (s, e) in slice.gapRanges) (s - startIndex, e - startIndex),
    ]);

    return _enqueue(() async {
      try {
        if (writeError != null) return;
        totalSamplesRecorded += count;
        final sink = _sink;
        if (sink == null) {
          // First packet: create dir + journal + this append in one go; the
          // journal needs ssnOrigin, which is exactly why it can't precede the
          // first append.
          final created = await _sinkFactory(
            sessionMetaFromHeader(header, _ssnOrigin!),
            bytes,
          );
          _sink = created;
          _sessionId = created.id;
          _ackedDataLength = bytes.lengthInBytes;
        } else {
          _ackedDataLength = await sink.append(bytes);
        }
      } catch (e) {
        // Latch the first failure; stop accumulating so we don't grow
        // unbounded after the sink has gone away (e.g. disk full / web quota
        // exceeded).
        debugPrint('Session write failed (session $sessionId): $e');
        _latchError(e);
      } finally {
        _unflushedSamples -= count;
      }
    });
  }

  /// Wait for every queued append to land. Serialized with appends.
  Future<void> flush() => _enqueue(() async {});

  /// Release the sink's open handle (at finalize/abort). Idempotent.
  Future<void> closeSink() async {
    final sink = _sink;
    _sink = null;
    await sink?.close();
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

/// The first-write factory's input/output: the meta to stamp into journal
/// line 1 plus the first packet's packed bytes, in; the open data sink out.
typedef SessionSinkFactory =
    Future<SessionDataSink> Function(SessionMeta meta, Uint8List firstData);
