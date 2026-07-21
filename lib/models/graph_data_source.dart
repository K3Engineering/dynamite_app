import 'package:flutter/foundation.dart';

import 'bucket_series.dart';
import 'gap_list.dart';

/// A single channel's raw circular-buffer data plus its precomputed extremes,
/// tare offset, and raw-value [BucketSeries]. Returned by
/// [GraphDataSource.channel].
typedef ChannelSeries = ({
  List<int> data,
  double min,
  double max,
  double tare,
  BucketSeries buckets,
});

/// Data interface required by the shared graph components (main graph,
/// minimap, etc.). Implemented directly by the two sources — [DataHub]
/// (live stream) and [SessionData] (static recording) — so the components
/// render either without an adapter layer.
///
/// Sources are not required to be [ChangeNotifier]s; instead they expose a
/// [repaint] [Listenable] that fires when their data changes (a never-firing
/// listenable is fine for static data). This keeps the interface usable by
/// both live and static sources, and leaves room for composed/derived
/// sources later.
abstract interface class GraphDataSource {
  /// Total number of logical samples generated so far (can exceed
  /// bufferCapacity).
  int get totalSamples;

  /// The size of the circular buffer. Used to modulus array indices.
  int get bufferCapacity;

  /// The oldest available sample index (absolute time).
  int get oldestSample;

  /// The sample rate of the data (Hz).
  int get sampleRate;

  /// The calibration slope used to convert raw counts to kgf.
  double get calibrationSlope;

  /// Notifies listeners when the underlying data changes.
  Listenable get repaint;

  /// Returns the series (data + extremes + tare + buckets) for a given
  /// channel index.
  ChannelSeries channel(int channelIndex);

  /// Bucket aggregates of the first-difference series for a channel,
  /// enabling the derivative graph's bucket fast path; null when the source
  /// does not track them (the derivative then renders on the exact path).
  /// Named `diffBucketsFor` so implementations may keep their
  /// `diffBuckets` accumulator field without a member collision.
  BucketSeries? diffBucketsFor(int channelIndex);

  /// Sample ranges where data was lost (dropped packets). The buffer holds
  /// held values there; renderers break the polyline and hatch these ranges.
  /// Sources that cannot have gaps return an empty (never-mutated) [GapList].
  GapList get gaps;
}

/// A [Listenable] that never fires; use as [GraphDataSource.repaint] for
/// static data sources (e.g. a loaded session).
final Listenable kNeverRepaints = _NeverListenable();

class _NeverListenable extends Listenable {
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}
