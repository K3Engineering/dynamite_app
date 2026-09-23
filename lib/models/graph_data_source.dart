import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'bucket_series.dart';
import 'channel_calibration.dart';
import 'channel_converter.dart';
import 'display_unit.dart';
import 'gap_list.dart';

/// Raw sample storage behind the graph components. [rawAt] is the only
/// accessor, so no storage layout crosses the interface. Dropped samples are
/// tracked in [gaps]; the held previous value is stored in their place, so
/// every stored value is a real reading.
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

/// Retained-range clamping and gap-aware per-sample evaluation, shared by
/// every consumer.
extension SampleStorageQueries on SampleStorage {
  /// Clamp the sample window `[start, end)` down to the retained range. The
  /// result may be empty (start >= end) — scan nothing then.
  (int, int) clampToRetained(int start, int end) =>
      (math.max(start, oldestSample), math.min(end, totalSamples));

  /// Raw value of channel [ch] at [j], or NaN when [j] is a gap sample (which
  /// breaks the polyline on the exact rendering paths).
  double rawValueAt(int ch, int j) =>
      gaps.contains(j) ? double.nan : rawAt(ch, j).toDouble();

  /// Whether a first difference can be formed at [j]; a held value on either
  /// side would fabricate flat or spiking results. Callers must pass j >= 1.
  /// Display-side twin of [ingestDiff].
  bool diffDefinedAt(int j) => !gaps.contains(j) && !gaps.contains(j - 1);

  /// Raw first difference at [j] (`sample j - sample j-1`), or NaN across a
  /// gap edge (see [diffDefinedAt]).
  double rawDiffAt(int ch, int j) => diffDefinedAt(j)
      ? (rawAt(ch, j) - rawAt(ch, j - 1)).toDouble()
      : double.nan;

  /// Standard deviation about the window's own mean of channel [ch] over
  /// `[start, end)`, clamped to retention. Gaps excluded. Null when the window
  /// holds no real sample.
  double? windowedStdDev(int ch, int start, int end) {
    final (s, e) = clampToRetained(start, end);
    double sum = 0, sumSq = 0;
    int count = 0;
    for (int i = s; i < e; i++) {
      final v = rawValueAt(ch, i);
      if (v.isNaN) continue;
      sum += v;
      sumSq += v * v;
      count++;
    }
    if (count == 0) return null;
    // E[x²] - E[x]²; fp rounding can push a hair below zero.
    return math.sqrt(
      (sumSq / count - (sum / count) * (sum / count)).clamp(
        0.0,
        double.infinity,
      ),
    );
  }
}

/// Per-channel aggregates over [SampleStorage]: the bucket accelerators and
/// whole-ingest extremes.
abstract interface class ChannelAggregates {
  /// Bucket aggregates of the raw value series, for the force graph's
  /// bucket fast path.
  BucketSeries valueBucketsFor(int channelIndex);

  /// Bucket aggregates of the first-difference series, same grid as
  /// [valueBucketsFor], for the derivative graph's fast path.
  BucketSeries diffBucketsFor(int channelIndex);

  /// Whole-ingest (min, max) of the channel's raw values, null on an empty
  /// stream/session. Never shrinks: the live hub's stream-lifetime peak, a
  /// loaded session's whole-session peak.
  (double, double)? channelExtremes(int channelIndex);
}

/// Per-channel conversion of raw counts to display units.
abstract interface class ChannelConversion {
  /// The channel's calibration. Read directly for snapshots and metadata;
  /// conversion goes through [converterFor].
  ChannelCalibration calibrationFor(int channelIndex);

  /// Which units this calibration converts right now (see
  /// `resolveUnitAvailability`). A property of the source, not the view.
  UnitAvailability get unitAvailability;

  /// The channel's calibration bound to its current tare offset.
  ChannelConverter converterFor(int channelIndex);

  /// Monotonic identity of the calibration set, mixed into segment-cache keys.
  /// Static sources return a constant.
  int get calibrationVersion;

  /// Monotonic identity of the tare set; unit-bound maps bake the tare in at
  /// bind time, so consumers rebind on this edge. Static sources return a
  /// constant.
  int get tareVersion;
}

/// Data interface for the shared graph components: storage, aggregates,
/// conversion, and a repaint identity. Implemented directly by [DataHub] (live)
/// and [SessionData] (static).
abstract interface class GraphDataSource
    implements SampleStorage, ChannelAggregates, ChannelConversion {
  Listenable get repaint;

  /// When the newest samples arrived (live sources); null for static sources.
  DateTime? get lastDataAt;

  /// Monotonic identity of the data stream; bumped on a reset for a NEW stream.
  /// Renderers mix it into segment-cache keys so baked content from a previous
  /// stream is dropped (both restart at absolute sample 0). Static sources
  /// return a constant.
  int get dataGeneration;
}

/// Windowed extremes over a full [GraphDataSource].
extension GraphSeriesQueries on GraphDataSource {
  /// Exact raw-space (min, max) of channel [ch] over `[start, end)` (clamped to
  /// retention), via the bucket fast path. Null when the window holds no
  /// sample. Gap samples contribute held values (they can't extend the range).
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
