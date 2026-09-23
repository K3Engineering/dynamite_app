import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';
import '../models/device_flash.dart';
import '../models/device_profile.dart';
import '../models/display_unit.dart';
import '../models/gap_list.dart';
import '../models/sample_slice.dart';
import '../utils/future_chain.dart';
import 'session_journal.dart';
import 'session_store_backend.dart';

/// The codec for a session directory's data.raw.
class SessionChunkCodec {
  const SessionChunkCodec(this.channelCount);

  final int channelCount;

  /// The 24-bit ADC range; int32 values outside it are reserved (see
  /// [gapSentinel]).
  static const int maxAdcValue = adcMaxValue;
  static const int minAdcValue = adcMinValue;

  /// The dropped-samples marker: a frame whose every channel reads it is a gap.
  /// A gap must be marked in-band because a loaded cell can legitimately repeat
  /// identical real values forever.
  static const int gapSentinel = 0x7FFFFFFF;

  /// Byte length of one packed sample frame.
  int get frameBytes => channelCount * 4;

  /// Whole sample frames in [bytes]. Callers decide what trailing partial
  /// bytes mean; [decodeWithGaps] rejects them as a torn write.
  int framesOf(Uint8List bytes) => bytes.lengthInBytes ~/ frameBytes;

  /// Pack [frames] samples as sample-major little-endian int32. [valueAt]
  /// returning anything outside the 24-bit range is an encoder bug and throws.
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

  /// Overwrite the sentinel on every channel of the whole frames in
  /// [gapRanges]. Ranges outside the buffer throw.
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
  /// [GapList] and hold-filling with the previous real value. [bytes] must
  /// divide into whole frames; a mixed/sentinel-first/out-of-range frame throws
  /// (states the write path never produces).
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

/// The [SessionMeta] fields snapshotted at recording start. ssnOrigin is the
/// one field that can only latch at the first append, so the journal's line 1
/// is written with the first data append.
typedef SessionHeader = ({
  String name,
  int sampleRate,
  int channelCount,
  List<String> channelLabels,
  List<double?> tares,
  List<ChannelCalibration> calibration,
  List<bool> visibleChannels,
  DisplayUnit displayUnit,
  Map<String, Object?> deviceInfo,
  KvsSnapshot? deviceKvs,
  String recordedAt,
});

/// The journal's line 1 from [header] plus the latched [ssnOrigin].
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
      deviceKvs: header.deviceKvs,
      recordedAt: header.recordedAt,
      ssnOrigin: ssnOrigin,
    );

/// The latched per-session run, created by the first packet's write; carries the
/// session's identity and persisted length. [LiveSessionWriter.closeSink]
/// releases the handle but keeps the run.
final class SessionRun {
  SessionRun(this.sink, this.id, this.ackedLength);

  /// The open data sink handle.
  final SessionDataSink sink;

  /// The session id (the directory's name).
  final String id;

  /// data.raw's byte length from the last acked append.
  int ackedLength;

  /// Whether [LiveSessionWriter.closeSink] released [sink].
  bool closed = false;
}

/// Streams recorded samples to the session's data.raw as they arrive: one
/// serialized write per accepted packet, so a session can outlive the ring and
/// a crash loses at most the in-flight packet. Writes are serialized through
/// [_writeQueue]; each [SampleSlice] is snapshotted at call time, so a stalled
/// queue never sees overwritten ring slots. If storage falls a full ring
/// behind, an error latches (see [appendData]).
class LiveSessionWriter {
  LiveSessionWriter(
    this.header, {
    required this.sourceRingCapacity,
    required this.onWriteError,
    required SessionSinkFactory sinkFactory,
  }) : _sinkFactory = sinkFactory;

  /// The journal-line-1 fields, carried until the first packet's write.
  final SessionHeader header;

  /// Null until the first packet's write creates the directory; then non-null
  /// for the writer's lifetime.
  SessionRun? get run => _run;
  SessionRun? _run;

  /// The session id, null until data exists (no artifact without data).
  String? get sessionId => _run?.id;

  /// The session's origin pair, latched together on the first [appendData]: the
  /// hub-absolute index of the first sample plus the device counter there.
  ({int originIdx, int ssnOrigin})? _origins;

  /// The device counter at the session's first sample; null before the first
  /// append.
  int? get ssnOrigin => _origins?.ssnOrigin;

  /// The rate stamped in the journal.
  int get sampleRate => header.sampleRate;

  /// Capacity of the producer's ring, the backlog bound for the backpressure
  /// latch in [appendData].
  final int sourceRingCapacity;

  /// Samples accepted by [appendData] but not yet written; the backpressure
  /// latch watches this.
  int _unflushedSamples = 0;

  /// Frames accepted for writing (the finalize check's "accepted" side).
  int totalSamplesRecorded = 0;

  /// Accepted frames × frame size; the run's acked length must equal this at
  /// finalize.
  int get expectedDataBytes =>
      totalSamplesRecorded *
      const SessionChunkCodec(kAdcChannelCount).frameBytes;

  /// First write failure encountered, if any. Once set it stays set.
  Object? writeError;
  bool get hasError => writeError != null;

  /// Called with the first failure the moment it latches, so recording's
  /// auto-stop doesn't wait for a later batch (or manual stop).
  final void Function(Object error) onWriteError;

  /// Latch [error] as the first failure and notify [onWriteError] once.
  void _latchError(Object error) {
    if (writeError != null) return;
    writeError = error;
    onWriteError.call(error);
  }

  /// Serializes all writes.
  final FutureChain _writeQueue = FutureChain();

  /// Opens the session on the first write and hands back its sink.
  final Future<SessionDataSink> Function(SessionMeta meta, Uint8List firstData)
  _sinkFactory;

  /// Append a fully snapshotted slice; returns when it has been written and
  /// flushed. Safe to call without awaiting (calls are serialized).
  Future<void> appendData(SampleSlice slice) {
    final origins = _origins ??= (
      originIdx: slice.startIndex,
      ssnOrigin:
          slice.anchor.counter + (slice.startIndex - slice.anchor.hubIndex),
    );

    final count = slice.sampleCount;
    _unflushedSamples += count;
    // Backpressure latch: an accepted-but-unwritten backlog over the ring
    // capacity means storage is a full ring behind; latch so the session
    // auto-stops. Checked at accept time.
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

    return _writeQueue.run(() async {
      try {
        if (writeError != null) return;
        totalSamplesRecorded += count;
        final existing = _run;
        if (existing == null) {
          // First packet: dir + journal + append in one go; the journal needs
          // ssnOrigin, so it can't precede the append.
          final created = await _sinkFactory(
            sessionMetaFromHeader(header, origins.ssnOrigin),
            bytes,
          );
          _run = SessionRun(created, created.id, bytes.lengthInBytes);
        } else {
          existing.ackedLength = await existing.sink.append(bytes);
        }
      } catch (e) {
        // Latch the first failure and stop accumulating.
        debugPrint('Session write failed (session $sessionId): $e');
        _latchError(e);
      } finally {
        _unflushedSamples -= count;
      }
    });
  }

  /// Wait for every queued append to land. Serialized with appends.
  Future<void> flush() => _writeQueue.run(() async {});

  /// Release the sink's handle. Idempotent; the run record outlives it.
  Future<void> closeSink() async {
    final run = _run;
    if (run == null || run.closed) return;
    run.closed = true;
    await run.sink.close();
  }
}

/// The first write's factory: meta + first packet in, open sink out.
typedef SessionSinkFactory =
    Future<SessionDataSink> Function(SessionMeta meta, Uint8List firstData);
