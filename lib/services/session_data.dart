import 'package:flutter/foundation.dart';

import '../models/board_calibration.dart';
import '../models/bucket_series.dart';
import '../models/channel_calibration.dart';
import '../models/channel_converter.dart';
import '../models/gap_list.dart';
import '../models/graph_data_source.dart';

/// The integrity verdict for a session's stored data, computed at load
/// time. Each flag maps to exactly one honest floor state (uncalibrated
/// channels, empty gaps, a truncated sample prefix) and one machine-readable
/// warning code carried in the CSV metadata's `warnings` field
/// (csv-format-v1.md). The UI renders a human interpretation of each
/// flag, never the code itself.
///
/// A damaged tare column sets no flag: its floor is null (no offset), which
/// is itself a first-class, honestly-rendered state — not a number posing
/// as a measurement.
class SessionDamage {
  const SessionDamage({
    this.calibration = false,
    this.gapsLost = false,
    this.boardMetaLost = false,
    this.truncatedAt,
  });

  static const none = SessionDamage();

  /// The calibration column failed to parse (whole column, board-uniform —
  /// a partially-malformed snapshot is damage, never a mixed board):
  /// channels floor to uncalibrated, so conversion reports unavailable and
  /// the view shows raw counts.
  final bool calibration;

  /// The gaps column failed to parse: dropout positions are unknown, so
  /// held (fabricated) values may appear as data and CSV gap rows can't be
  /// blanked. The sample stream itself is intact.
  final bool gapsLost;

  /// The board-metadata column failed to parse: the calibration provenance
  /// (cal.* fields, constants verdict, calDataInvalid) the session was
  /// recorded under is lost. The conversion numbers themselves
  /// ([calibration]) are separate and may be intact.
  final bool boardMetaLost;

  /// Chunk data failed integrity at this sample index (a missing chunk,
  /// a misaligned blob, or disagreement with the metadata's sample count):
  /// samples from here on are shown neither in the view nor in the CSV —
  /// they remain available via the salvage export.
  final int? truncatedAt;

  bool get isEmpty =>
      !calibration && !gapsLost && !boardMetaLost && truncatedAt == null;

  /// The machine-readable codes for the set flags — the CSV `warnings`
  /// metadata field's contract (the UI banner interprets them instead of
  /// quoting them).
  List<String> get warningCodes => [
    if (calibration) 'session_calibration_damaged',
    if (gapsLost) 'session_gaps_lost',
    if (boardMetaLost) 'session_board_meta_damaged',
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

  /// Per-channel tare offsets in counts, frozen at record start; null =
  /// that channel was recording gross (never tared). A damaged column
  /// floors to all-null at load (see SessionStorage.loadSession).
  final List<double?> tares;

  /// The board-level calibration provenance frozen at record start
  /// (see [SessionBoardMeta]). Null for sessions recorded with no board
  /// data resolved, or on a damaged board-meta column (which sets
  /// [SessionDamage.boardMetaLost] instead).
  final SessionBoardMeta? boardMeta;

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
  /// [AppDatabase.appendChunkAndGaps]); a crash before the first flush leaves
  /// this empty.
  @override
  final GapList gaps;

  /// The storage-integrity verdict for this session (see [SessionDamage]).
  /// Healthy sessions carry [SessionDamage.none].
  final SessionDamage damage;

  /// Per-channel whole-session extremes, derived by the load-time ingest
  /// (same [ChannelIngest] tracker as the live hub's stream-lifetime peaks).
  final List<double?> mins;
  final List<double?> maxs;

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
    this.boardMeta,
    GapList? gaps,
  }) : gaps = gaps ?? GapList(),
       mins = List.filled(channels.length, null),
       maxs = List.filled(channels.length, null) {
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
      final ingest = ChannelIngest(
        valueBuckets: valueBuckets[ch],
        diffBuckets: diffBuckets[ch],
        gaps: this.gaps,
      );

      for (int i = 0; i < sampleCount; i++) {
        ingest.add(i, channels[ch][i], i > 0 ? channels[ch][i - 1] : 0);
      }
      final ext = ingest.extremes; // non-null: sampleCount > 0 here
      mins[ch] = ext!.$1.toDouble();
      maxs[ch] = ext.$2.toDouble();
    }
  }

  double get durationSeconds => sampleCount / sampleRate;

  // -- GraphDataSource --------------------------------------------------------

  @override
  int get totalSamples => sampleCount;

  /// The whole session is retained, so its retention bound is its length.
  @override
  int get bufferCapacity => sampleCount;

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
  ChannelSeries channel(int channelIndex) => (
    min: mins[channelIndex],
    max: maxs[channelIndex],
    tare: tares[channelIndex],
    buckets: valueBuckets[channelIndex].series,
  );

  @override
  BucketSeries diffBucketsFor(int channelIndex) =>
      diffBuckets[channelIndex].series;
}
