import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../models/graph_data_source.dart';
import 'metrics_sway.dart';
import 'plate_series.dart';
import 'test_result.dart';

// ---------------------------------------------------------------------------
// Single-leg stance
//
// The window is fixed (e.g. 30 s); the rep is the longest interval inside
// it where one side of the plate is unloaded — the other foot held the
// weight. The interval starts at contralateral toe-off (no button press)
// and ends when that foot touches the plate again, or the window ends.
// Metrics run on the interval itself, so re-evaluating a stored session
// needs no re-detection.
// ---------------------------------------------------------------------------

/// Tunables of single-leg detection. Fractions are of body weight.
@immutable
class SingleLegParams {
  const SingleLegParams({
    this.unloadFraction = 0.15,
    this.onsetSustainMs = 150,
    this.reloadSustainMs = 300,
    this.minHoldMs = 3000,
  });

  /// A side counts as off when it carries less than this fraction of body
  /// weight.
  final double unloadFraction;

  /// Toe-off must hold this long.
  final int onsetSustainMs;

  /// Reload (foot back down) must hold this long.
  final int reloadSustainMs;

  /// A shorter lift isn't a stance attempt (a scratch, a weight shift).
  final int minHoldMs;
}

const SingleLegParams kSingleLegParams = SingleLegParams();

/// The located single-leg interval inside a window.
@immutable
class SingleLegInterval {
  const SingleLegInterval({
    required this.start,
    required this.end,
    required this.loadedLeft,
  });

  /// `[start, end)` in absolute samples.
  final int start;
  final int end;

  /// Which side stayed on the plate (the stance leg).
  final bool loadedLeft;
}

/// Find the longest single-leg interval in [w], or null when none reaches
/// [SingleLegParams.minHoldMs]. An interval ends at the first reload
/// (either side climbs back over the threshold, sustained), or at the
/// window's end — still balancing when the timer ran out counts.
SingleLegInterval? findSingleLegInterval(
  PlateWindow w, {
  required double bwKgf,
  SingleLegParams params = kSingleLegParams,
}) {
  final threshold = params.unloadFraction * bwKgf;
  final onset = math.max(1, params.onsetSustainMs * w.sampleRate ~/ 1000);
  final reload = math.max(1, params.reloadSustainMs * w.sampleRate ~/ 1000);
  final minHold = params.minHoldMs * w.sampleRate ~/ 1000;

  /// In single-leg stance: the light side is off AND the total is still
  /// body-ish. The total floor ends the interval on a hop-off (emptied
  /// plate), the threshold ends it on a touch-down.
  bool liftedAt(int i) {
    final l = w.leftAt(i);
    final r = w.rightAt(i);
    return math.min(l, r) < threshold && l + r > 0.5 * bwKgf;
  }

  bool sustained(bool Function(int) pred, int from, int count) {
    for (int k = 0; k < count; k++) {
      if (!pred(from + k)) return false;
    }
    return true;
  }

  SingleLegInterval? best;
  var scan = w.start;
  while (scan + onset < w.end) {
    if (!sustained(liftedAt, scan, onset)) {
      scan++;
      continue;
    }
    // Interval opens; find where the stance breaks (foot down or hop-off),
    // or the window ends with the athlete still balancing.
    var close = w.end;
    for (int i = scan + onset; i + reload <= w.end; i++) {
      if (sustained((i) => !liftedAt(i), i, reload)) {
        close = i;
        break;
      }
    }
    if (close - scan >= minHold) {
      double left = 0, right = 0;
      for (int i = scan; i < close; i++) {
        left += w.leftAt(i);
        right += w.rightAt(i);
      }
      final candidate = SingleLegInterval(
        start: scan,
        end: close,
        loadedLeft: left >= right,
      );
      if (best == null || close - scan > best.end - best.start) {
        best = candidate;
      }
    }
    scan = math.max(scan + 1, close);
  }
  return best;
}

// -- Metrics --

/// One entry in the single-leg metric table.
@immutable
class SlMetricDef {
  const SlMetricDef({
    required this.id,
    required this.label,
    required this.unit,
    required this.decimals,
    required this.compute,
  });

  final String id;
  final String label;
  final String unit;
  final int decimals;

  final double? Function(PlateWindow w) compute;
}

/// A computed metric value; null when not meaningful for this hold.
@immutable
class SlMetricValue {
  const SlMetricValue(this.def, this.value);
  final SlMetricDef def;
  final double? value;
}

/// One evaluated single-leg hold (shared live / summary / re-opened
/// session).
@immutable
class SlRepResult {
  const SlRepResult({
    required this.number,
    required this.label,
    required this.start,
    required this.end,
    required this.sampleRate,
    required this.values,
    required this.ellipse,
  });

  final int number;

  /// "Left leg" / "Right leg" — the stance side.
  final String label;

  /// The located interval `[start, end)` in samples.
  final int start;
  final int end;
  final int sampleRate;

  final List<SlMetricValue> values;

  /// The CoP confidence ellipse over the hold, for the plate-pane overlay.
  final CopEllipse? ellipse;

  double? metric(String id) {
    for (final v in values) {
      if (v.def.id == id) return v.value;
    }
    return null;
  }
}

/// CoP path length in millimetres over the hold.
double? _pathMm(PlateWindow w) {
  double sum = 0;
  (double, double)? prev;
  int n = 0;
  for (int i = w.start; i < w.end; i++) {
    final cop = w.copAt(i);
    if (cop == null) continue;
    n++;
    if (prev != null) {
      final dx = (cop.$1 - prev.$1) * w.geometry.supportHalfWidthMm;
      final dy = (cop.$2 - prev.$2) * w.geometry.supportHalfLengthMm;
      sum += math.sqrt(dx * dx + dy * dy);
    }
    prev = cop;
  }
  return n < 2 ? null : sum;
}

/// The single-leg metric table, in display order.
final List<SlMetricDef> slMetrics = List.unmodifiable([
  SlMetricDef(
    id: 'hold_duration',
    label: 'Hold duration',
    unit: 's',
    decimals: 1,
    compute: (w) => w.length / w.sampleRate,
  ),
  const SlMetricDef(
    id: 'sway_path',
    label: 'CoP path length',
    unit: 'mm',
    decimals: 0,
    compute: _pathMm,
  ),
  SlMetricDef(
    id: 'mean_cop_velocity',
    label: 'Mean CoP velocity',
    unit: 'mm/s',
    decimals: 1,
    compute: (w) {
      final path = _pathMm(w);
      if (path == null) return null;
      return path / (w.length / w.sampleRate);
    },
  ),
  const SlMetricDef(
    id: 'stance_load',
    label: 'Load on stance side',
    unit: '%',
    decimals: 1,
    compute: _stanceLoad,
  ),
]);

/// Share of the window's impulse borne by the interval's loaded side — a
/// true single-leg stand reads close to 100, a cheat reads less.
double? _stanceLoad(PlateWindow w) {
  double left = 0, right = 0;
  for (int i = w.start; i < w.end; i++) {
    left += w.leftAt(i);
    right += w.rightAt(i);
  }
  final total = left + right;
  if (!(total > 0)) return null;
  return 100 * math.max(left, right) / total;
}

/// Evaluate one single-leg interval window.
SlRepResult evaluateSlWindow(PlateWindow w, String label, int number) =>
    SlRepResult(
      number: number,
      label: label,
      start: w.start,
      end: w.end,
      sampleRate: w.sampleRate,
      values: [for (final def in slMetrics) SlMetricValue(def, def.compute(w))],
      ellipse: copConfidenceEllipse(w),
    );

/// Recompute every hold's metrics for [result] against a loaded recording.
/// Empty when the plate can't be read or a stored window falls outside it.
List<SlRepResult> evaluateSlResult(TestResult result, GraphDataSource data) {
  final reader = PlateReader.tryForData(data);
  if (reader == null) return const [];
  final reps = <SlRepResult>[];
  for (int i = 0; i < result.reps.length; i++) {
    final rep = result.reps[i];
    if (rep.start < data.oldestSample || rep.end > data.totalSamples) {
      continue;
    }
    reps.add(
      evaluateSlWindow(
        PlateWindow.capture(reader, rep.start, rep.end),
        rep.label ?? '',
        i + 1,
      ),
    );
  }
  return reps;
}
