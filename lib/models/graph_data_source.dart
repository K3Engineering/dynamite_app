import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'bucket_series.dart';
import 'channel_calibration.dart';
import 'channel_converter.dart';
import 'gap_list.dart';

/// A single channel's precomputed extremes, tare offset, and raw-value
/// [BucketSeries]. Returned by [GraphDataSource.channel]. Extreme values are
/// null on an empty session.
typedef ChannelSeries = ({
  double? min,
  double? max,
  double? tare,
  BucketSeries buckets,
});

/// Data interface required by the shared graph components (main graph,
/// minimap, etc.). Implemented directly by the two sources — [DataHub]
/// (live stream) and [SessionData] (static recording) — so the components
/// render either without an adapter layer.
///
/// Consumers read samples ONLY through [rawAt] (and the [GraphSeriesQueries]
/// helpers built on it): neither the ring's modulo convention nor any other
/// storage layout leaks across this interface.
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

  /// Retention bound: the most samples the source can present at once (its
  /// ring capacity, or a session's whole length). Viewport controllers clamp
  /// visible spans against it.
  int get bufferCapacity;

  /// The oldest available sample index (absolute time).
  int get oldestSample;

  /// The sample rate of the data (Hz).
  int get sampleRate;

  /// Sample [index] of [channelIndex] in raw counts: the single accessor
  /// over the source's storage layout (ring slot, flat array, ...). Callers
  /// must keep [index] inside [[oldestSample], [totalSamples]).
  int rawAt(int channelIndex, int index);

  /// The per-channel calibration used to convert raw counts to display
  /// units (board piecewise map + assigned load cell). Read directly for
  /// calibration snapshots and metadata; CONVERSION goes through
  /// [converterFor].
  ChannelCalibration calibrationFor(int channelIndex);

  /// The channel's converter: its calibration bound to its current tare
  /// offset, so one lookup yields everything a consumer converts through.
  ChannelConverter converterFor(int channelIndex);

  /// Monotonic identity of the calibration set: bumped when calibration
  /// changes (factory data arrives, a load-cell assignment changes), so
  /// renderers can mix it into their segment-cache keys alongside
  /// [dataGeneration]. Static sources return a constant.
  int get calibrationVersion;

  Listenable get repaint;

  /// Wall-clock time when the newest samples arrived (the latest batch
  /// commit for a live source); null for static sources.
  DateTime? get lastDataAt;

  /// Monotonic identity of the data stream backing this source: bumped when
  /// the source is reset for a NEW stream (e.g. [DataHub.clear] on
  /// reconnect), unchanged while the same stream merely grows. Renderers mix
  /// it into their segment-cache keys, so baked content from a previous
  /// stream is dropped instead of being blitted over the new stream's data
  /// (both restart at absolute sample 0). Static sources return a constant.
  int get dataGeneration;

  /// Returns the series (extremes + tare + buckets) for a given
  /// channel index.
  ChannelSeries channel(int channelIndex);

  /// Bucket aggregates of the first-difference series for a channel,
  /// enabling the derivative graph's bucket fast path. Both implementations
  /// track them; named `diffBucketsFor` so implementations may keep their
  /// `diffBuckets` accumulator field without a member collision.
  BucketSeries diffBucketsFor(int channelIndex);

  /// Sample ranges where data was lost (dropped packets). The buffer holds
  /// held values there; renderers break the polyline and hatch these ranges.
  /// Sources that cannot have gaps return an empty (never-mutated) [GapList].
  GapList get gaps;
}

/// Queries shared by every [GraphDataSource] consumer: retained-range
/// clamping, gap-aware per-sample evaluation, and bucket-accelerated windowed
/// extremes. One place owns the conventions so call sites stop re-deriving
/// them (window clamps, NaN-on-gap rules).
extension GraphSeriesQueries on GraphDataSource {
  /// Clamp the sample window `[start, end)` down to the retained range. The
  /// result may be empty (start >= end) — scan nothing then.
  (int, int) clampToRetained(int start, int end) =>
      (math.max(start, oldestSample), math.min(end, totalSamples));

  /// Raw value of channel [ch] at [j] as a double, or NaN when [j] is a gap
  /// sample. The NaN rule is the polyline-breaking contract of the exact
  /// rendering paths.
  double rawValueAt(int ch, int j) =>
      gaps.contains(j) ? double.nan : rawAt(ch, j).toDouble();

  /// Raw first difference at [j] (`sample j - sample j-1`), or NaN across a
  /// gap edge: a held value on either side would fabricate a flat or spiking
  /// derivative. Callers must pass j >= 1 (the derivative view skips sample 0
  /// via `firstSampleOffset`). Display-side twin of [ingestDiff]'s ingest
  /// rule (which writes 0 instead of NaN).
  double rawDiffAt(int ch, int j) {
    if (gaps.contains(j) || gaps.contains(j - 1)) return double.nan;
    return (rawAt(ch, j) - rawAt(ch, j - 1)).toDouble();
  }

  /// Exact raw-space (min, max) of channel [ch] over `[start, end)` (clamped
  /// to the retained range — callers may pass an unclamped view window), via
  /// the bucket fast path: full buckets fold from the precomputed aggregates,
  /// only the partial head/tail scan per-sample. Null when the clamped
  /// window holds no sample. Gap samples contribute their held values (they
  /// can never extend the range), matching the envelope rendering.
  (double, double)? windowedRawExtremes(int ch, int start, int end) {
    final (s, e) = clampToRetained(start, end);
    if (s >= e) return null;
    return windowedExtremes(
      channel(ch).buckets,
      s,
      e,
      (i) => rawAt(ch, i).toDouble(),
    );
  }
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
