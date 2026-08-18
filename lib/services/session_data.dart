import 'package:flutter/foundation.dart';

import '../models/bucket_series.dart';
import '../models/channel_calibration.dart';
import '../models/gap_list.dart';
import 'graph_data_source.dart';

/// Loaded session data for playback/review.
class SessionData implements GraphDataSource {
  final List<Int32List> channels;
  @override
  final int sampleRate;
  final int sampleCount;

  /// Per-channel calibration snapshots recorded with the session.
  final List<ChannelCalibration> calibrations;
  final List<double> tares;

  /// Device sample-counter value at the session's first sample (the
  /// dynamite-csv `ssn_origin`), latched by the live writer from the first
  /// recorded packet and persisted on the session row. Null only for
  /// sessions finalized before any packet arrived (which have no data to
  /// export) or pre-column rows; exporters fall back to 0.
  final int? ssnOrigin;

  /// Dropped-sample ranges (session-relative). The channel data holds held
  /// values across these ranges, so stats/buckets need no exclusion logic;
  /// renderers use this to hatch and break the polyline, and CSV export
  /// blanks these rows. Crash-recovered sessions keep the ranges the live
  /// writer persisted incrementally up to its last chunk flush (see
  /// [AppDatabase.setSessionGaps]); a crash before the first flush leaves
  /// this empty.
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
  final int bucketSize = kBucketSize;
  late final List<BucketAccumulator> valueBuckets;

  /// Per-channel bucket aggregates of the first-difference series
  /// (`diff[i] = raw[i] - raw[i-1]`), same bucket grid. Used by the
  /// derivative graph's bucket fast path; the gap/first-sample diff rule
  /// lives in [ingestDiff], applied through the same [ChannelIngest] the
  /// live hub uses.
  late final List<BucketAccumulator> diffBuckets;

  SessionData({
    required this.channels,
    required this.sampleRate,
    required this.sampleCount,
    required this.calibrations,
    required this.tares,
    GapList? gaps,
    this.ssnOrigin,
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
      final ingest = ChannelIngest(
        valueBuckets: valueBuckets[ch],
        diffBuckets: diffBuckets[ch],
        gaps: this.gaps,
      );

      for (int i = 0; i < sampleCount; i++) {
        final v = channels[ch][i];
        if (v < mn) mn = v.toDouble();
        if (v > mx) mx = v.toDouble();
        ingest.add(i, v, i > 0 ? channels[ch][i - 1] : 0);
      }
      mins[ch] = mn;
      maxs[ch] = mx;
    }
  }

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

  /// Static data has no arrival clock.
  @override
  DateTime? get lastDataAt => null;

  /// Session data is immutable after load; there is no "new stream".
  @override
  int get dataGeneration => 0;

  @override
  ChannelCalibration calibrationFor(int channelIndex) =>
      calibrations[channelIndex];

  /// Session calibration is frozen at recording time; it never changes.
  @override
  int get calibrationVersion => 0;

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
