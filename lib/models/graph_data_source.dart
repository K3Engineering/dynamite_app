import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'bucket_series.dart';
import 'channel_calibration.dart';
import 'channel_converter.dart';
import 'derived_channel.dart';
import 'display_unit.dart';
import 'gap_list.dart';

/// Raw sample storage behind the graph components. [rawAt] is the only
/// accessor, so no storage layout crosses the interface. Dropped samples are
/// tracked in [gaps]; the held previous value is stored in their place, so
/// every stored value is a real reading.
///
/// Channel ids: [0, kAdcChannelCount) are hardware channels (raw counts);
/// ids starting at kAdcChannelCount are derived channels (see
/// `derived_channel.dart`), stored in their own quantized ring space.
abstract interface class SampleStorage {
  /// Total number of logical samples generated so far (can exceed the
  /// retained window).
  int get totalSamples;

  /// The oldest available sample index (absolute time); `totalSamples -
  /// oldestSample` is the retained window.
  int get oldestSample;

  /// The sample rate of the data (Hz).
  int get sampleRate;

  /// Sample [index] of [channelIndex] in the channel's raw ring units.
  /// Callers must keep [index] inside [[oldestSample], [totalSamples]).
  int rawAt(int channelIndex, int index);

  /// Sample ranges where data was lost (dropped packets). The storage holds
  /// held values there; renderers break the polyline and hatch these
  /// ranges. Sources that cannot have gaps return an empty (never-mutated)
  /// [GapList].
  GapList get gaps;

  /// Whether the value at [index] of [channelIndex] is a defined reading:
  /// false inside gaps (held values) and at undefined derived samples (a
  /// normalized channel with member sum ≤ 0 — the ring holds there too).
  bool channelSampleDefined(int channelIndex, int index);
}

/// Retained-range clamping and gap-aware per-sample evaluation, shared by
/// every consumer.
extension SampleStorageQueries on SampleStorage {
  /// Clamp the sample window `[start, end)` down to the retained range. The
  /// result may be empty (start >= end) — scan nothing then.
  (int, int) clampToRetained(int start, int end) =>
      (math.max(start, oldestSample), math.min(end, totalSamples));

  /// Raw value of channel [ch] at [j], or NaN when the sample is undefined
  /// (a gap or an undefined derived sample — breaking the polyline on the
  /// exact rendering paths).
  double rawValueAt(int ch, int j) =>
      channelSampleDefined(ch, j) ? rawAt(ch, j).toDouble() : double.nan;

  /// Whether a first difference can be formed at [j]; a held value on either
  /// side would fabricate flat or spiking results. Callers must pass j >= 1.
  /// Display-side twin of [ingestDiff]. Gap-edges only: a derived channel's
  /// held (undefined) samples legitimately read as a zero rate.
  bool diffDefinedAt(int j) => !gaps.contains(j) && !gaps.contains(j - 1);

  /// Raw first difference at [j] (`sample j - sample j-1`), or NaN across a
  /// gap edge (see [diffDefinedAt]).
  double rawDiffAt(int ch, int j) => diffDefinedAt(j)
      ? (rawAt(ch, j) - rawAt(ch, j - 1)).toDouble()
      : double.nan;

  /// Standard deviation about the window's own mean of channel [ch] over
  /// `[start, end)`, clamped to retention. Undefined samples excluded. Null
  /// when the window holds no real sample.
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

  /// Whole-ingest (min, max) of the channel's raw ring values, null on an
  /// empty stream/session or an unbound channel. Never shrinks: the live
  /// hub's stream-lifetime peak, a loaded session's whole-session peak.
  (double, double)? channelExtremes(int channelIndex);
}

/// Per-channel conversion of raw counts to display units.
abstract interface class ChannelConversion {
  /// The channel's calibration. Hardware channels only ([channelIndex] <
  /// kAdcChannelCount) — derived channels have no calibration of their own.
  /// Read directly for snapshots and metadata; conversion goes through
  /// [converterFor].
  ChannelCalibration calibrationFor(int channelIndex);

  /// Which units this calibration converts right now (see
  /// `resolveUnitAvailability`). A property of the source, not the view.
  UnitAvailability get unitAvailability;

  /// The channel's calibration bound to its current tare offset. Hardware
  /// channels only.
  ChannelConverter converterFor(int channelIndex);

  /// Monotonic identity of the calibration set, mixed into segment-cache keys.
  /// Static sources return a constant.
  int get calibrationVersion;

  /// Monotonic identity of the tare set; unit-bound maps bake the tare in at
  /// bind time, so consumers rebind on this edge. Static sources return a
  /// constant.
  int get tareVersion;
}

/// Display conversion of ANY channel's stored (ring) values into
/// [DisplayUnit]s — the widened twin of [ChannelConverter] spanning
/// hardware and derived channels. A hardware channel's raw space is ADC
/// counts; a derived channel's is its quantized ring space (see
/// `derived_series.dart`).
abstract interface class SeriesConverter {
  /// Ring value -> display value, net of tare; null when [unit] can't
  /// convert on this channel (a force unit with no load cell, a blend
  /// channel asked for mV/V).
  double Function(double raw)? netMap(DisplayUnit unit);

  /// Ring diff -> display diff (tare cancels); null exactly when
  /// [netMap] is.
  double Function(double rawDiff)? diffMap(DisplayUnit unit);

  /// The channel's full-scale span in RING units: the FFT's dBFS reference
  /// (2^23 for hardware, the blends' summed rail span, 1/quantum for
  /// ratios — so a full-range ratio reads 0 dBFS).
  double get fullScaleRaw;

  /// Unitless channel (a normalized blend): display maps ignore [unit].
  bool get unitless;
}

/// Hardware [SeriesConverter]: a [ChannelConverter] with the ADC rail as
/// the full-scale reference.
final class HardwareSeriesConverter implements SeriesConverter {
  const HardwareSeriesConverter(this._inner);

  final ChannelConverter _inner;

  @override
  double Function(double raw)? netMap(DisplayUnit unit) => _inner.netMap(unit);

  @override
  double Function(double rawDiff)? diffMap(DisplayUnit unit) =>
      _inner.diffMap(unit);

  @override
  double get fullScaleRaw => 8388608; // 2^23 counts

  @override
  bool get unitless => false;
}

/// The converter of an unbound channel: every unit is unavailable.
final class UnboundSeriesConverter implements SeriesConverter {
  const UnboundSeriesConverter();

  @override
  double Function(double raw)? netMap(DisplayUnit unit) => null;

  @override
  double Function(double rawDiff)? diffMap(DisplayUnit unit) => null;

  @override
  double get fullScaleRaw => 1;

  @override
  bool get unitless => false;
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

  /// Total channel count: the hardware channels plus [derivedChannels].
  int get channelCount;

  /// The rig's derived channels in id order (id = kAdcChannelCount +
  /// index); empty when the rig defines none. Availability (members
  /// calibrated) is per-channel via [seriesConverterFor]'s null maps — an
  /// unbound channel keeps its id slot.
  List<DerivedChannelSpec> get derivedChannels;

  /// The rig's math-channel profile: [MathProfile.specs] is
  /// [derivedChannels], and the plate semantics (axis/error ids) the Plate
  /// pane binds. The live hub's is the current config; a session's is the
  /// record-time snapshot.
  MathProfile get mathProfile;

  /// Display conversion for any channel id in [0, channelCount).
  SeriesConverter seriesConverterFor(int id);

  /// The hardware channels' tares the id reads, for the segment caches'
  /// destructive key (a hardware channel: its own; a derived blend: its
  /// members').
  List<double?> cacheTaresFor(int id);
}

/// Windowed extremes over a full [GraphDataSource].
extension GraphSeriesQueries on GraphDataSource {
  /// Whether [id] is unconvertible ONLY because it's a force-space blend
  /// asked for an electrical unit (all members calibrated, so a force unit
  /// would bind). These channels refuse electrical units by construction
  /// (a blend's storage is kgf — see `derived_series.dart`); the UI names
  /// them with a "switch to a force unit" hint rather than the generic
  /// unavailable line.
  bool isForceOnlyBlend(int id, DisplayUnit unit) {
    if (!isDerivedChannelId(id) || unit.isForce) return false;
    final idx = derivedIndexOf(id);
    if (idx >= derivedChannels.length) return false;
    final spec = derivedChannels[idx];
    if (spec.normalize) return false;
    return spec.members.every(
      (m) =>
          calibrationFor(m).board != null && calibrationFor(m).loadCell != null,
    );
  }

  /// Exact raw-space (min, max) of channel [ch] over `[start, end)` (clamped to
  /// retention), via the bucket fast path. Null when the window holds no
  /// sample. Held samples (gaps, undefined ratios) can't extend the range.
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
