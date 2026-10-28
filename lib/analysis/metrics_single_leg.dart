import 'dart:math' as math;

import 'package:material_ui/material_ui.dart' show Color;
import 'package:meta/meta.dart';

import '../models/graph_overlays.dart';
import 'metric_eval.dart';
import 'metrics_sway.dart' show copConfidenceEllipse;
import 'plate_series.dart';
import 'result_overlays.dart';
import 'test_family.dart';

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
  const new({
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
  const new({required this.start, required this.end, required this.loadedLeft});

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

/// The single-leg metric table, in display order. (Window-only metrics: no
/// evaluation context beyond the window itself.)
final List<MetricDef<Object?>> slMetrics = List.unmodifiableOf([
  MetricDef<Object?>(
    id: 'hold_duration',
    label: 'Hold duration',
    unit: 's',
    decimals: 1,
    compute: (w, _) => w.length / w.sampleRate,
  ),
  MetricDef<Object?>(
    id: 'sway_path',
    label: 'CoP path length',
    unit: 'mm',
    decimals: 0,
    compute: (w, _) => w.copPathLengthMm,
  ),
  MetricDef<Object?>(
    id: 'mean_cop_velocity',
    label: 'Mean CoP velocity',
    unit: 'mm/s',
    decimals: 1,
    compute: (w, _) {
      final path = w.copPathLengthMm;
      if (path == null) return null;
      return path / (w.length / w.sampleRate);
    },
  ),
  MetricDef<Object?>(
    id: 'stance_load',
    label: 'Load on stance side',
    unit: '%',
    decimals: 1,
    compute: (w, _) => _stanceLoad(w),
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

/// Evaluate one single-leg interval window as the family-neutral
/// [EvaluatedRep]: the whole interval is the rep, shaded faintly on the force
/// trace, with a CoP confidence ellipse on the plate pane.
EvaluatedRep evaluateSlWindow(PlateWindow w, String label, int number) {
  final eval = RepEvaluation(
    number: number,
    label: label.isEmpty ? null : label,
    start: w.start,
    end: w.end,
    values: evaluateMetrics(w, slMetrics, null),
  );
  return EvaluatedRep(
    eval: eval,
    overlays: GraphOverlays(
      spans: windowShadeOverlay(eval).spans,
      plateEllipses: [
        if (copConfidenceEllipse(w) case final e?)
          PlateEllipseOverlay(
            cx: e.cx,
            cy: e.cy,
            semiA: e.semiA,
            semiB: e.semiB,
            angleRad: e.angleRad,
            color: const Color(0xFF9C27B0),
          ),
      ],
    ),
  );
}
