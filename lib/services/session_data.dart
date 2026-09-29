import 'package:flutter/foundation.dart';

import '../models/bucket_series.dart';
import '../models/channel_calibration.dart';
import '../models/channel_converter.dart';
import '../models/derived_channel.dart';
import '../models/derived_series.dart';
import '../models/device_flash.dart';
import '../models/device_profile.dart';
import '../models/display_unit.dart';
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

  /// The rig's math-channel profile, snapshotted into the session at
  /// record start (older sessions take the loader's current config — see
  /// `session_store.dart`), replayed over the frozen calibrations/tares at
  /// load. [derivedSpecs] is its channel set in id order (see
  /// `derived_channel.dart`).
  @override
  final MathProfile mathProfile;

  /// The profile's derived channels in id order (see [derivedChannels]).
  List<DerivedChannelSpec> get derivedSpecs => mathProfile.specs;

  /// Per-spec ingest runtimes; null slots couldn't bind on the session's
  /// frozen calibration set (see [DerivedChannelRuntime.tryBuild]).
  late final List<DerivedChannelRuntime?> _derived;

  SessionData({
    required this.channels,
    required this.sampleRate,
    required this.sampleCount,
    required this.calibrations,
    required this.tares,
    required this.ssnOrigin,
    this.deviceKvs,
    MathProfile? mathProfile,
    GapList? gaps,
  }) : mathProfile = mathProfile ?? MathProfile.none(),
       gaps = gaps ?? GapList(),
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

    // Derived channels replay over the same frames; calibration and tares
    // are frozen, so a single load-time pass is the whole story.
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
            gaps: this.gaps,
          ),
      ];
      for (int i = 0; i < sampleCount; i++) {
        for (int c = 0; c < kAdcChannelCount; c++) {
          scratch[c] = channels[c][i];
        }
        final held = this.gaps.contains(i);
        for (final rt in _derived) {
          if (rt == null) continue;
          held ? rt.addHeld(i) : rt.addFrame(i, scratch);
        }
      }
    }
  }

  double get durationSeconds => sampleCount / sampleRate;

  // -- GraphDataSource --------------------------------------------------------

  @override
  int get totalSamples => sampleCount;

  @override
  int get oldestSample => 0;

  @override
  int rawAt(int channelIndex, int index) => channelIndex < kAdcChannelCount
      ? channels[channelIndex][index]
      : (_derivedAt(derivedIndexOf(channelIndex))?.ring[index] ?? 0);

  @override
  bool channelSampleDefined(int channelIndex, int index) {
    if (gaps.contains(index)) return false;
    if (channelIndex < kAdcChannelCount) return true;
    return _derivedAt(derivedIndexOf(channelIndex))?.validAt(index) ?? false;
  }

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
  UnitAvailability get unitAvailability =>
      resolveUnitAvailability(calibrationFor);

  @override
  ChannelConverter converterFor(int channelIndex) =>
      ChannelConverter(calibrations[channelIndex], tares[channelIndex]);

  /// Session calibration is frozen at recording time; it never changes.
  @override
  int get calibrationVersion => 0;

  /// Session tares are frozen at recording time; they never change.
  @override
  int get tareVersion => 0;

  @override
  BucketSeries valueBucketsFor(int channelIndex) =>
      channelIndex < kAdcChannelCount
      ? _valueBuckets[channelIndex].series
      : (_derivedAt(derivedIndexOf(channelIndex))?.valueSeries ??
            _kEmptyBuckets);

  @override
  BucketSeries diffBucketsFor(int channelIndex) =>
      channelIndex < kAdcChannelCount
      ? _diffBuckets[channelIndex].series
      : (_derivedAt(derivedIndexOf(channelIndex))?.diffSeries ??
            _kEmptyBuckets);

  /// Aggregates of an unbound derived channel: empty (the converters
  /// report every unit unavailable).
  static final BucketSeries _kEmptyBuckets = BucketAccumulator(
    bucketSize: kBucketSize,
    numBuckets: 0,
  ).series;

  @override
  (double, double)? channelExtremes(int channelIndex) {
    if (channelIndex >= kAdcChannelCount) {
      final ext = _derivedAt(derivedIndexOf(channelIndex))?.extremes;
      return ext == null ? null : (ext.$1.toDouble(), ext.$2.toDouble());
    }
    return _extremes[channelIndex];
  }

  /// The runtime for a derived index, or null when unbound or past the
  /// configured set (see [DataHub._derivedAt]).
  DerivedChannelRuntime? _derivedAt(int index) =>
      index < _derived.length ? _derived[index] : null;

  @override
  int get channelCount => channels.length + derivedSpecs.length;

  @override
  List<DerivedChannelSpec> get derivedChannels => derivedSpecs;

  @override
  SeriesConverter seriesConverterFor(int id) => id < kAdcChannelCount
      ? HardwareSeriesConverter(converterFor(id))
      : (_derivedAt(derivedIndexOf(id))?.converterFor() ??
            const UnboundSeriesConverter());

  @override
  List<double?> cacheTaresFor(int id) => id < kAdcChannelCount
      ? [tares[id]]
      : [
          if (derivedIndexOf(id) < derivedSpecs.length)
            for (final m in derivedSpecs[derivedIndexOf(id)].members) tares[m],
        ];
}
