import 'package:flutter/foundation.dart';

import '../models/bucket_series.dart';
import '../models/channel_calibration.dart';
import '../models/display_unit.dart';
import '../models/gap_list.dart';
import '../models/graph_data_source.dart';

/// The integrity verdict for a session's stored data, computed at load
/// time. Each flag maps to exactly one honest floor state (zeroed tares,
/// uncalibrated channels, empty gaps, a truncated sample prefix) and one
/// machine-readable warning code, shared verbatim between the UI banner
/// and the CSV metadata's `warnings` field (docs/csv-format-v1.md).
class SessionDamage {
  const SessionDamage({
    this.tare = false,
    this.calibration = false,
    this.gapsLost = false,
    this.truncatedAt,
  });

  static const none = SessionDamage();

  /// The tare column failed to parse: stored tares are floored to zero, so
  /// views show gross counts and conversion is forced to raw (a zero tare
  /// is a legitimate recorded value, so only this flag distinguishes
  /// "damaged" from "never tared").
  final bool tare;

  /// The calibration column failed to parse (whole column, board-uniform —
  /// a partially-malformed snapshot is damage, never a mixed board):
  /// channels floor to uncalibrated, so conversion reports unavailable and
  /// the view shows raw counts.
  final bool calibration;

  /// The gaps column failed to parse: dropout positions are unknown, so
  /// held (fabricated) values may appear as data and CSV gap rows can't be
  /// blanked. The sample stream itself is intact.
  final bool gapsLost;

  /// Chunk data failed integrity at this sample index (a missing chunk,
  /// a misaligned blob, or disagreement with the metadata's sample count):
  /// samples from here on are shown neither in the view nor in the CSV —
  /// they remain available via the salvage export.
  final int? truncatedAt;

  bool get isEmpty => !tare && !calibration && !gapsLost && truncatedAt == null;

  /// The machine-readable codes for the set flags, shared verbatim between
  /// the UI banner and the CSV `warnings` metadata field.
  List<String> get warningCodes => [
    if (tare) 'session_tare_damaged',
    if (calibration) 'session_calibration_damaged',
    if (gapsLost) 'session_gaps_lost',
    if (truncatedAt case final t?) 'session_truncated_at_sample:$t',
  ];
}

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
  /// recorded packet and written into the session row when the first chunk
  /// flush created it — so it always exists for any session that has data.
  final int ssnOrigin;

  /// Dropped-sample ranges (session-relative). The channel data holds held
  /// values across these ranges, so stats/buckets need no exclusion logic;
  /// renderers use this to hatch and break the polyline, and CSV export
  /// blanks these rows. Crash-recovered sessions keep the ranges the live
  /// writer persisted incrementally up to its last chunk flush (see
  /// [AppDatabase.setSessionGaps]); a crash before the first flush leaves
  /// this empty.
  @override
  final GapList gaps;

  /// The storage-integrity verdict for this session (see [SessionDamage]).
  /// Healthy sessions carry [SessionDamage.none].
  final SessionDamage damage;

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
    required this.ssnOrigin,
    this.damage = SessionDamage.none,
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

  /// The unit set this session can convert right now: the nominal lookup,
  /// forced raw-only when tare or calibration metadata is damaged — the
  /// floors those flags carry (zeroed tares, uncalibrated channels) must
  /// never produce converted numbers that pose as net measurements.
  UnitAvailability unitAvailabilityFor(Iterable<int> activeChannels) {
    if (damage.tare || damage.calibration) {
      return (boardHasNominals: false, anyActiveHasLoadCell: false);
    }
    return resolveUnitAvailability(calibrationFor, activeChannels);
  }

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
