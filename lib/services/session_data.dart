import 'package:flutter/foundation.dart';

import '../models/bucket_series.dart';
import '../models/channel_calibration.dart';
import '../models/channel_converter.dart';
import '../models/derived_channel.dart';
import '../models/derived_dispatch.dart';
import '../models/derived_series.dart';
import '../models/device_flash.dart';
import '../models/device_profile.dart';
import '../models/display_unit.dart';
import '../models/gap_list.dart';
import '../models/graph_data_source.dart';
import 'session_preparation.dart';

/// Loaded session data for playback/review. Derived channels (ids >=
/// kAdcChannelCount, see `derived_channel.dart`) ride along via
/// [DerivedDispatch].
class SessionData with DerivedDispatch implements GraphDataSource {
  final List<Int32List> channels;
  @override
  final int sampleRate;
  final int sampleCount;

  /// Per-channel calibration snapshots recorded with the session.
  final List<ChannelCalibration> calibrations;

  /// Per-channel tare offsets in counts, frozen at record start; null =
  /// that channel was recording gross (never tared).
  final List<double?> tares;

  /// The raw device KVS snapshot frozen at record start; null for sessions
  /// recorded before this provenance field existed.
  final KvsSnapshot? deviceKvs;

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
  final List<(double, double)?> _extremes;

  /// Per-channel bucket aggregates over [bucketSize]-sample windows of the
  /// raw values. Mirrors DataHub's live buckets (same [BucketAccumulator])
  /// so the graphs can downsample cheaply. Gap samples hold the previous
  /// real value, so buckets are always fully populated and need no
  /// missing-data handling.
  final int bucketSize = kBucketSize;
  final List<BucketAccumulator> _valueBuckets;

  /// Per-channel bucket aggregates of the first-difference series
  /// (`diff[i] = raw[i] - raw[i-1]`), same bucket grid. Used by the
  /// derivative graph's bucket fast path; the gap/first-sample diff rule
  /// lives in [ingestDiff], applied through the same [ChannelIngest] the
  /// live hub uses.
  final List<BucketAccumulator> _diffBuckets;

  /// The rig's math-channel profile, snapshotted into the session at
  /// record start (older sessions take the loader's current config — see
  /// `session_store.dart`), replayed over the frozen calibrations/tares at
  /// load. [derivedSpecs] is its channel set in id order (see
  /// `derived_channel.dart`).
  @override
  final MathProfile mathProfile;

  /// The profile's derived channels in id order (see [derivedChannels]).
  @override
  List<DerivedChannelSpec> get derivedSpecs => mathProfile.specs;

  /// Per-spec ingest runtimes; null slots couldn't bind on the session's
  /// frozen calibration set (see [DerivedChannelRuntime.tryBuild]).
  late final List<DerivedChannelRuntime?> _derived;

  /// Reuses the hardware aggregates from [decodeAndPrepareSession], then
  /// replays the samples needed by the session's math-channel profile.
  new fromPrepared({
    required PreparedSessionData prepared,
    required this.sampleRate,
    required this.tares,
    required this.ssnOrigin,
    this.deviceKvs,
    MathProfile? mathProfile,
  }) : mathProfile = mathProfile ?? MathProfile.none(),
       channels = prepared.channels,
       calibrations = prepared.calibrations,
       sampleCount = prepared.sampleCount,
       gaps = prepared.gaps,
       _extremes = prepared.extremes,
       _valueBuckets = prepared.valueBuckets,
       _diffBuckets = prepared.diffBuckets {
    final int numBuckets = (sampleCount == 0)
        ? 0
        : ((sampleCount - 1) ~/ bucketSize) + 1;
    if (channels.length < kAdcChannelCount || sampleCount == 0) {
      _derived = List.filled(derivedSpecs.length, null);
    } else {
      final scratch = Int32List(kAdcChannelCount);
      _derived = [
        for (final spec in derivedSpecs)
          DerivedChannelRuntime.tryBuild(
            spec,
            calibrations,
            tares,
            bucketSize: bucketSize,
            numBuckets: numBuckets,
            ringSize: sampleCount,
            gaps: gaps,
          ),
      ];
      for (int i = 0; i < sampleCount; i++) {
        for (int c = 0; c < kAdcChannelCount; c++) {
          scratch[c] = channels[c][i];
        }
        final held = gaps.contains(i);
        for (final rt in _derived) {
          if (rt == null) continue;
          held ? rt.addHeld(i) : rt.addFrame(i, scratch);
        }
      }
    }
  }

  // -- GraphDataSource --------------------------------------------------------

  @override
  int get totalSamples => sampleCount;

  @override
  int get oldestSample => 0;

  @override
  int get maxViewableSamples => sampleCount;

  @override
  int rawAt(int channelIndex, int index) => channelIndex < kAdcChannelCount
      ? channels[channelIndex][index]
      : (derivedAt(derivedIndexOf(channelIndex))?.ring[index] ?? 0);

  @override
  Listenable get repaint => kNeverRepaints;

  /// Static data has no arrival clock.
  @override
  DateTime? get lastDataAt => null;

  /// Static data has no live device clock.
  @override
  double? projectedEndAt() => null;

  /// Session data is immutable after load; there is no "new stream".
  @override
  int get dataGeneration => 0;

  @override
  ChannelCalibration calibrationFor(int channelIndex) =>
      calibrations[channelIndex];

  @override
  UnitAvailability get unitAvailability =>
      resolveUnitAvailability(calibrations);

  @override
  ChannelConverter converterFor(int channelIndex) =>
      ChannelConverter(calibrations[channelIndex], tares[channelIndex]);

  /// Session calibration is frozen at recording time; it never changes.
  @override
  int get calibrationVersion => 0;

  /// Session tares are frozen at recording time; they never change.
  @override
  int get tareVersion => 0;

  // -- DerivedDispatch hooks (hardware halves; the derived id dispatch lives
  // in the mixin) -----------------------------------------------------------

  @override
  List<DerivedChannelRuntime?> get derivedRuntimes => _derived;

  @override
  BucketSeries hardwareValueBuckets(int channelIndex) =>
      _valueBuckets[channelIndex].series;

  @override
  BucketSeries hardwareDiffBuckets(int channelIndex) =>
      _diffBuckets[channelIndex].series;

  @override
  (double, double)? hardwareExtremes(int channelIndex) =>
      _extremes[channelIndex];

  @override
  double? hardwareTare(int channelIndex) => tares[channelIndex];

  /// The recorded hardware channel count, not [kAdcChannelCount]: a session
  /// stores exactly the channels its recorder had.
  @override
  int get channelCount => channels.length + derivedSpecs.length;
}
