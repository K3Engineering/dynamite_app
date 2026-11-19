import 'dart:typed_data';

import '../models/bucket_series.dart';
import '../models/channel_calibration.dart';
import '../models/gap_list.dart';
import 'live_session_writer.dart';

/// All sample-derived state behind a loaded [SessionData]. The calibration is
/// retained with it because bucket mV/V sums and SessionData's unit converters
/// must use the same board maps.
class PreparedSessionData {
  const new _({
    required this.channels,
    required this.calibrations,
    required this.gaps,
    required this.valueBuckets,
    required this.diffBuckets,
    required this.extremes,
  });

  final List<Int32List> channels;
  final List<ChannelCalibration> calibrations;
  final GapList gaps;
  final List<BucketAccumulator> valueBuckets;
  final List<BucketAccumulator> diffBuckets;
  final List<(double, double)?> extremes;

  int get sampleCount => channels.first.length;
}

/// Aggregate construction for the packed-byte decoder. ChannelIngest remains
/// the definition of value, difference, gap and extrema behavior for both live
/// and recorded data.
class _AggregateBuilder {
  new _(
    this._ingests,
    this._valueBuckets,
    this._diffBuckets,
    this.calibrations,
  );

  factory create(
    int sampleCount,
    List<ChannelCalibration> calibrations,
    GapList gaps,
  ) {
    final int numBuckets = sampleCount == 0
        ? 0
        : ((sampleCount - 1) ~/ kBucketSize) + 1;
    final valueBuckets = List.generate(
      calibrations.length,
      (i) => BucketAccumulator(
        bucketSize: kBucketSize,
        numBuckets: numBuckets,
        mvVOf: switch (calibrations[i].board) {
          final board? => (raw) => board.mvVFromRaw(raw.toDouble()),
          null => null,
        },
      ),
    );
    final diffBuckets = List.generate(
      calibrations.length,
      (_) => BucketAccumulator(bucketSize: kBucketSize, numBuckets: numBuckets),
    );
    return _AggregateBuilder._(
      [
        for (int ch = 0; ch < calibrations.length; ch++)
          ChannelIngest(
            valueBuckets: valueBuckets[ch],
            diffBuckets: diffBuckets[ch],
            gaps: gaps,
          ),
      ],
      valueBuckets,
      diffBuckets,
      calibrations,
    );
  }

  final List<ChannelIngest> _ingests;
  final List<ChannelCalibration> calibrations;
  final List<BucketAccumulator> _valueBuckets;
  final List<BucketAccumulator> _diffBuckets;

  void add(int sampleIndex, int channel, int value, int prevValue) {
    _ingests[channel].add(sampleIndex, value, prevValue);
  }

  PreparedSessionData complete(List<Int32List> channels, GapList gaps) =>
      PreparedSessionData._(
        channels: List.unmodifiableOf(channels),
        calibrations: List.unmodifiableOf(calibrations),
        gaps: gaps,
        valueBuckets: List.unmodifiableOf(_valueBuckets),
        diffBuckets: List.unmodifiableOf(_diffBuckets),
        extremes: List.unmodifiableOf([
          for (final ingest in _ingests)
            switch (ingest.extremes) {
              final ext? => (ext.$1.toDouble(), ext.$2.toDouble()),
              null => null,
            },
        ]),
      );
}

/// Strictly decode packed sample frames and build every graph aggregate in the
/// same frame-major traversal. Invalid bytes discard the local preparation by
/// throwing; no partially decoded or partially aggregated result escapes.
PreparedSessionData decodeAndPrepareSession({
  required SessionChunkCodec codec,
  required Uint8List bytes,
  required List<ChannelCalibration> calibrations,
}) {
  if (codec.channelCount <= 0) {
    throw ArgumentError.value(
      codec.channelCount,
      'codec.channelCount',
      'must be positive',
    );
  }
  final calibrationsSnapshot = List.unmodifiableOf(calibrations);
  if (calibrationsSnapshot.length != codec.channelCount) {
    throw ArgumentError.value(
      calibrationsSnapshot.length,
      'calibrations',
      'must contain one entry per data channel (${codec.channelCount})',
    );
  }
  if (bytes.lengthInBytes % codec.frameBytes != 0) {
    throw StateError(
      '${bytes.lengthInBytes} data bytes do not divide into whole '
      '${codec.frameBytes}-byte frames — a torn mid-frame write is damage, '
      'not a shorter recording',
    );
  }

  final view = ByteData.sublistView(bytes);
  final frames = codec.framesOf(bytes);
  final channels = List.generate(codec.channelCount, (_) => Int32List(frames));
  final gaps = GapList();
  final aggregates = _AggregateBuilder.create(
    frames,
    calibrationsSnapshot,
    gaps,
  );

  for (int s = 0; s < frames; s++) {
    final base = s * codec.channelCount * 4;
    bool isGap = false;
    for (int ch = 0; ch < codec.channelCount; ch++) {
      final raw = view.getInt32(base + ch * 4, Endian.little);
      final hereGap = raw == SessionChunkCodec.gapSentinel;
      if (ch > 0 && hereGap != isGap) {
        throw StateError(
          'frame $s mixes sentinel and real channel values — '
          'the write path fills gap frames whole',
        );
      }
      isGap = hereGap;
      if (!isGap) {
        if (raw < SessionChunkCodec.minAdcValue ||
            raw > SessionChunkCodec.maxAdcValue) {
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
      for (int ch = 0; ch < codec.channelCount; ch++) {
        channels[ch][s] = channels[ch][s - 1];
      }
    }
    for (int ch = 0; ch < codec.channelCount; ch++) {
      aggregates.add(s, ch, channels[ch][s], s > 0 ? channels[ch][s - 1] : 0);
    }
  }
  return aggregates.complete(channels, gaps);
}
