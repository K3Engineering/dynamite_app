import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'bucket_series.dart';
import 'channel_calibration.dart';
import 'channel_converter.dart';
import 'gap_list.dart';

/// Raw sample storage behind the graph components: [totalSamples] and
/// [oldestSample] define the retained window on an absolute timeline, and
/// [rawAt] is the single accessor over the storage layout (ring slot, flat
/// array, ...) — no layout convention (the ring's modulo, a backing array)
/// crosses this interface.
///
/// Dropped samples are tracked out-of-band in [gaps]; the storage holds the
/// held previous value there, so every stored value is a real reading and
/// consumers need no magic-value checks.
abstract interface class SampleStorage {
  /// Total number of logical samples generated so far (can exceed the
  /// retained window).
  int get totalSamples;

  /// The oldest available sample index (absolute time); `totalSamples -
  /// oldestSample` is the retained window.
  int get oldestSample;

  /// The sample rate of the data (Hz).
  int get sampleRate;

  /// Sample [index] of [channelIndex] in raw counts. Callers must keep
  /// [index] inside [[oldestSample], [totalSamples]).
  int rawAt(int channelIndex, int index);

  /// Sample ranges where data was lost (dropped packets). The storage holds
  /// held values there; renderers break the polyline and hatch these
  /// ranges. Sources that cannot have gaps return an empty (never-mutated)
  /// [GapList].
  GapList get gaps;
}

/// Queries over raw storage shared by every consumer: retained-range
/// clamping and gap-aware per-sample evaluation. One place owns the
/// conventions so call sites stop re-deriving them (window clamps,
/// NaN-on-gap rules).
extension SampleStorageQueries on SampleStorage {
  /// Clamp the sample window `[start, end)` down to the retained range. The
  /// result may be empty (start >= end) — scan nothing then.
  (int, int) clampToRetained(int start, int end) =>
      (math.max(start, oldestSample), math.min(end, totalSamples));

  /// Raw value of channel [ch] at [j] as a double, or NaN when [j] is a gap
  /// sample. The NaN rule is the polyline-breaking contract of the exact
  /// rendering paths.
  double rawValueAt(int ch, int j) =>
      gaps.contains(j) ? double.nan : rawAt(ch, j).toDouble();

  /// Whether a first difference can be formed at [j]: a held value on
  /// either side would fabricate a flat or spiking derivative, so every
  /// reader excludes gap edges (renderers via NaN, the stats display via a
  /// 0 report). Callers must pass j >= 1. Display-side twin of
  /// [ingestDiff]'s ingest rule (which writes 0 into the bucket aggregates
  /// instead of excluding the sample).
  bool diffDefinedAt(int j) => !gaps.contains(j) && !gaps.contains(j - 1);

  /// Raw first difference at [j] (`sample j - sample j-1`), or NaN across a
  /// gap edge (see [diffDefinedAt]).
  double rawDiffAt(int ch, int j) => diffDefinedAt(j)
      ? (rawAt(ch, j) - rawAt(ch, j - 1)).toDouble()
      : double.nan;
}

/// Per-channel derived aggregates over [SampleStorage]: the bucket
/// accelerators for the graph renderers' block reductions and the
/// whole-ingest extremes.
abstract interface class ChannelAggregates {
  /// Bucket aggregates of the raw value series, for the force graph's
  /// bucket fast path.
  BucketSeries valueBucketsFor(int channelIndex);

  /// Bucket aggregates of the first-difference series
  /// (`diff[j] = raw[j] - raw[j-1]`), same bucket grid as
  /// [valueBucketsFor], for the derivative graph's fast path. Named
  /// `diffBucketsFor` so implementations may keep their `diffBuckets`
  /// accumulator field without a member collision.
  BucketSeries diffBucketsFor(int channelIndex);

  /// Whole-ingest (min, max) of the channel's raw values, null on an empty
  /// stream/session. Never shrinks: the live hub's stream-lifetime peak, a
  /// loaded session's whole-session peak.
  (double, double)? channelExtremes(int channelIndex);
}

/// Per-channel conversion of raw counts to display units (and the
/// calibration behind it).
abstract interface class ChannelConversion {
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
  /// [GraphDataSource.dataGeneration]. Static sources return a constant.
  int get calibrationVersion;
}

/// Data interface required by the shared graph components (main graph,
/// minimap, etc.): storage, derived aggregates, and conversion, plus the
/// change-notification identity of a source. Implemented directly by the
/// two sources — [DataHub] (live stream) and [SessionData] (static
/// recording) — so the components render either without an adapter layer.
///
/// Sources are not required to be [ChangeNotifier]s; instead they expose a
/// [repaint] [Listenable] that fires when their data changes (a never-firing
/// listenable is fine for static data). This keeps the interface usable by
/// both live and static sources, and leaves room for composed/derived
/// sources later.
abstract interface class GraphDataSource
    implements SampleStorage, ChannelAggregates, ChannelConversion {
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
}

/// Queries over a full [GraphDataSource]: the windowed extremes need both
/// the storage accessors and the bucket aggregates.
extension GraphSeriesQueries on GraphDataSource {
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
      valueBucketsFor(ch),
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
