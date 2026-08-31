import 'package:flutter/foundation.dart';

import '../models/board_calibration.dart';
import '../models/bucket_series.dart';
import '../models/channel_calibration.dart';
import '../models/channel_converter.dart';
import '../models/gap_list.dart';
import '../models/graph_data_source.dart';

/// Loaded session data for playback/review.
class SessionData implements GraphDataSource {
  final List<Int32List> channels;
  @override
  final int sampleRate;
  final int sampleCount;

  /// Per-channel calibration snapshots recorded with the session.
  final List<ChannelCalibration> calibrations;

  /// Per-channel tare offsets in counts, frozen at record start; null =
  /// that channel was recording gross (never tared).
  final List<double?> tares;

  /// The board-level calibration provenance frozen at record start
  /// (see [SessionBoardMeta]). Null for sessions recorded with no board
  /// data resolved.
  final SessionBoardMeta? boardMeta;

  /// Device sample-counter value at the session's first sample (the
  /// dynamite-csv `ssn_origin`), latched by the live writer from the first
  /// recorded packet and stamped into the journal when the first packet
  /// created the session — so it always exists for any session that has data.
  final int ssnOrigin;

  /// Dropped-sample ranges (session-relative), reconstructed at load from
  /// the data stream's in-band gap sentinels. The channel data holds held
  /// values across these ranges, so stats/buckets need no exclusion logic;
  /// renderers use this to hatch and break the polyline, and CSV export
  /// blanks these rows.
  @override
  final GapList gaps;

  /// Per-channel whole-session extremes, derived by the load-time ingest
  /// (same [ChannelIngest] tracker as the live hub's stream-lifetime
  /// peaks); null per channel on an empty session.
  late final List<(double, double)?> _extremes;

  /// Per-channel bucket aggregates over [bucketSize]-sample windows of the
  /// raw values. Mirrors DataHub's live buckets (same [BucketAccumulator])
  /// so the graphs can downsample cheaply. Gap samples hold the previous
  /// real value, so buckets are always fully populated and need no
  /// missing-data handling.
  final int bucketSize = kBucketSize;
  late final List<BucketAccumulator> _valueBuckets;

  /// Per-channel bucket aggregates of the first-difference series
  /// (`diff[i] = raw[i] - raw[i-1]`), same bucket grid. Used by the
  /// derivative graph's bucket fast path; the gap/first-sample diff rule
  /// lives in [ingestDiff], applied through the same [ChannelIngest] the
  /// live hub uses.
  late final List<BucketAccumulator> _diffBuckets;

  SessionData({
    required this.channels,
    required this.sampleRate,
    required this.sampleCount,
    required this.calibrations,
    required this.tares,
    required this.ssnOrigin,
    this.boardMeta,
    GapList? gaps,
  }) : gaps = gaps ?? GapList(),
       _extremes = List.filled(channels.length, null) {
    final int numBuckets = (sampleCount == 0)
        ? 0
        : ((sampleCount - 1) ~/ bucketSize) + 1;
    _valueBuckets = List.generate(
      channels.length,
      (_) => BucketAccumulator(bucketSize: bucketSize, numBuckets: numBuckets),
    );
    _diffBuckets = List.generate(
      channels.length,
      (_) => BucketAccumulator(bucketSize: bucketSize, numBuckets: numBuckets),
    );

    for (int ch = 0; ch < channels.length; ch++) {
      if (sampleCount == 0) continue;
      final ingest = ChannelIngest(
        valueBuckets: _valueBuckets[ch],
        diffBuckets: _diffBuckets[ch],
        gaps: this.gaps,
      );

      for (int i = 0; i < sampleCount; i++) {
        ingest.add(i, channels[ch][i], i > 0 ? channels[ch][i - 1] : 0);
      }
      final ext = ingest.extremes; // non-null: sampleCount > 0 here
      _extremes[ch] = (ext!.$1.toDouble(), ext.$2.toDouble());
    }
  }

  double get durationSeconds => sampleCount / sampleRate;

  // -- GraphDataSource --------------------------------------------------------

  @override
  int get totalSamples => sampleCount;

  @override
  int get oldestSample => 0;

  @override
  int rawAt(int channelIndex, int index) => channels[channelIndex][index];

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

  @override
  ChannelConverter converterFor(int channelIndex) =>
      ChannelConverter(calibrations[channelIndex], tares[channelIndex]);

  /// Session calibration is frozen at recording time; it never changes.
  @override
  int get calibrationVersion => 0;

  @override
  BucketSeries valueBucketsFor(int channelIndex) =>
      _valueBuckets[channelIndex].series;

  @override
  BucketSeries diffBucketsFor(int channelIndex) =>
      _diffBuckets[channelIndex].series;

  @override
  (double, double)? channelExtremes(int channelIndex) =>
      _extremes[channelIndex];
}
