import 'bucket_series.dart';
import 'channel_converter.dart';
import 'derived_channel.dart';
import 'derived_series.dart';
import 'device_profile.dart';
import 'gap_list.dart';
import 'graph_data_source.dart';

// ---------------------------------------------------------------------------
// Derived-channel id dispatch
//
// The widened channel id space (see `derived_channel.dart`) routes the same
// way for every store that carries derived channels: ids < kAdcChannelCount
// hit the host's hardware storage (the `hardwareX` hooks), ids from
// kAdcChannelCount hit the per-spec [DerivedChannelRuntime]s, and an unbound
// runtime (or an id past the configured set — callers may enumerate a wider
// id space, e.g. toggled-but-removed channels) reads as empty and converts
// nothing. Shared by DataHub (live) and SessionData (a loaded session) so
// the dispatch exists once; the hosts keep only their storage-specific
// halves.
// ---------------------------------------------------------------------------

/// Derived-channel [GraphDataSource] member implementations; see the file
/// header. Mixed into a store that also satisfies the interface's hardware
/// half.
mixin DerivedDispatch {
  /// Per-spec ingest runtimes in id order; null slots can't bind (see
  /// [DerivedChannelRuntime.tryBuild]).
  List<DerivedChannelRuntime?> get derivedRuntimes;

  /// The host's configured derived channels in id order.
  List<DerivedChannelSpec> get derivedSpecs;

  /// Everything below plus [gaps] come from the store's own interface; the
  /// mixin can't name that constraint (Dart mixins have no implements), so
  /// they are redeclared here.

  /// See SampleStorage.gaps.
  GapList get gaps;

  /// See ChannelConversion.converterFor.
  ChannelConverter converterFor(int channelIndex);

  /// The host's hardware-side halves, by hardware channel index: the raw
  /// bucket aggregates, the whole-ingest (min, max), and the tare.
  BucketSeries hardwareValueBuckets(int channelIndex);
  BucketSeries hardwareDiffBuckets(int channelIndex);
  (double, double)? hardwareExtremes(int channelIndex);
  double? hardwareTare(int channelIndex);

  /// Aggregates of an unbound derived channel: empty, so windowed folds
  /// find nothing there (its converter reports every unit unavailable).
  static final BucketSeries emptyDerivedBuckets = BucketAccumulator(
    bucketSize: kBucketSize,
    numBuckets: 0,
  ).series;

  /// The runtime for a derived index, or null when unbound — or when the
  /// id is past the configured set (callers may enumerate a wider id space
  /// than this store's config, e.g. toggled-but-removed channels).
  DerivedChannelRuntime? derivedAt(int index) =>
      index < derivedRuntimes.length ? derivedRuntimes[index] : null;

  /// See SampleStorage.channelSampleDefined.
  bool channelSampleDefined(int channelIndex, int index) {
    if (gaps.contains(index)) return false;
    if (channelIndex < kAdcChannelCount) return true;
    return derivedAt(derivedIndexOf(channelIndex))?.validAt(index) ?? false;
  }

  /// See GraphDataSource.channelCount.
  int get channelCount => kAdcChannelCount + derivedSpecs.length;

  /// See GraphDataSource.derivedChannels.
  List<DerivedChannelSpec> get derivedChannels => derivedSpecs;

  /// See GraphDataSource.seriesConverterFor.
  SeriesConverter seriesConverterFor(int id) => id < kAdcChannelCount
      ? HardwareSeriesConverter(converterFor(id))
      : (derivedAt(derivedIndexOf(id))?.converterFor() ??
            const UnboundSeriesConverter());

  /// See GraphDataSource.cacheTaresFor.
  List<double?> cacheTaresFor(int id) => id < kAdcChannelCount
      ? [hardwareTare(id)]
      : [
          if (derivedIndexOf(id) < derivedSpecs.length)
            for (final m in derivedSpecs[derivedIndexOf(id)].members)
              hardwareTare(m),
        ];

  /// See ChannelAggregates.valueBucketsFor.
  BucketSeries valueBucketsFor(int channelIndex) =>
      channelIndex < kAdcChannelCount
      ? hardwareValueBuckets(channelIndex)
      : (derivedAt(derivedIndexOf(channelIndex))?.valueSeries ??
            emptyDerivedBuckets);

  /// See ChannelAggregates.diffBucketsFor.
  BucketSeries diffBucketsFor(int channelIndex) =>
      channelIndex < kAdcChannelCount
      ? hardwareDiffBuckets(channelIndex)
      : (derivedAt(derivedIndexOf(channelIndex))?.diffSeries ??
            emptyDerivedBuckets);

  /// See ChannelAggregates.channelExtremes.
  (double, double)? channelExtremes(int channelIndex) {
    if (channelIndex >= kAdcChannelCount) {
      final ext = derivedAt(derivedIndexOf(channelIndex))?.extremes;
      return ext == null ? null : (ext.$1.toDouble(), ext.$2.toDouble());
    }
    return hardwareExtremes(channelIndex);
  }
}
