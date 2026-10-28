import 'dart:math' as math;

import 'package:material_ui/material_ui.dart' show Color;

import '../models/graph_overlays.dart';
import 'metric_eval.dart';
import 'plate_series.dart';
import 'result_overlays.dart';
import 'test_family.dart';

// ---------------------------------------------------------------------------
// Quiet-stance (sway) metrics
//
// Each metric is a pure function of a captured window, so the same
// definitions serve the live runner and a re-opened session. CoP positions
// are support-normalized in the window; the window's [PlateGeometry] turns
// them into millimetres for path/area/RMS numbers.
// ---------------------------------------------------------------------------

/// Chi-square value for the 95% prediction ellipse of a 2-D normal cloud
/// (2 degrees of freedom).
const double kEllipseChi2_95 = 5.991;

/// A planar confidence ellipse over the window's CoP samples, in support-
/// normalized plate units (±1 = a plate edge). Null when the window has too
/// few defined CoP samples to fit.
typedef CopEllipse = ({
  double cx,
  double cy,
  double semiA,
  double semiB,
  double angleRad,
});

/// Iterate samples where the plate carries a positive load (CoP defined),
/// yielding (index, x, y). Windows during quiet stance are loaded
/// throughout; the filter only drops the ringing edge cases.
Iterable<(int, double, double)> _copSamples(PlateWindow w) sync* {
  for (int i = w.start; i < w.end; i++) {
    final cop = w.copAt(i);
    if (cop != null) yield (i, cop.$1, cop.$2);
  }
}

/// Mean CoP speed: path length over the window's duration.
double? _meanVelocity(PlateWindow w) {
  final path = w.copPathLengthMm;
  if (path == null) return null;
  return path / (w.length / w.sampleRate);
}

/// Root-mean-square CoP position about its mean, per axis, in millimetres.
double? _rmsMm(PlateWindow w, bool horizontal) {
  double sum = 0, sumSq = 0;
  int n = 0;
  for (final (_, x, y) in _copSamples(w)) {
    final v = horizontal ? x : y;
    sum += v;
    sumSq += v * v;
    n++;
  }
  if (n == 0) return null;
  final variance = (sumSq / n - (sum / n) * (sum / n)).clamp(
    0.0,
    double.infinity,
  );
  final half = horizontal
      ? w.geometry.supportHalfWidthMm
      : w.geometry.supportHalfLengthMm;
  return math.sqrt(variance) * half;
}

/// Mean left/right load share: left force over total, as a percentage.
/// Null when the mean total is not positive (empty-plate window).
double? _leftShare(PlateWindow w) {
  double left = 0, right = 0;
  for (int i = w.start; i < w.end; i++) {
    left += w.leftAt(i);
    right += w.rightAt(i);
  }
  final total = left + right;
  if (!(total > 0)) return null;
  return 100 * left / total;
}

/// The 95% prediction ellipse of the window's CoP cloud (PCA: eigen of the
/// 2×2 covariance). Null with fewer than two defined samples.
CopEllipse? copConfidenceEllipse(PlateWindow w) {
  double sumX = 0, sumY = 0, sxx = 0, syy = 0, sxy = 0;
  int n = 0;
  for (final (_, x, y) in _copSamples(w)) {
    sumX += x;
    sumY += y;
    sxx += x * x;
    syy += y * y;
    sxy += x * y;
    n++;
  }
  if (n < 2) return null;
  final cx = sumX / n;
  final cy = sumY / n;
  final cxx = math.max(0.0, sxx / n - cx * cx);
  final cyy = math.max(0.0, syy / n - cy * cy);
  final cxy = sxy / n - cx * cy;
  final trace = cxx + cyy;
  final disc = math.sqrt((cxx - cyy) * (cxx - cyy) + 4 * cxy * cxy);
  final lambda1 = (trace + disc) / 2;
  final lambda2 = math.max(0.0, (trace - disc) / 2);
  // λ1's eigenvector: both algebraic forms solve it, but each degenerates
  // when its partner term vanishes (axis-aligned clouds), so use the
  // longer one.
  final ax1 = cxy, ay1 = lambda1 - cxx;
  final bx1 = lambda1 - cyy, by1 = cxy;
  final lenA = ax1 * ax1 + ay1 * ay1;
  final lenB = bx1 * bx1 + by1 * by1;
  final angle = lenA >= lenB ? math.atan2(ay1, ax1) : math.atan2(by1, bx1);
  final k = math.sqrt(kEllipseChi2_95);
  return (
    cx: cx,
    cy: cy,
    semiA: k * math.sqrt(lambda1),
    semiB: k * math.sqrt(lambda2),
    angleRad: angle,
  );
}

/// Ellipse area in millimetres².
double? _area95(PlateWindow w) {
  final e = copConfidenceEllipse(w);
  if (e == null) return null;
  return math.pi *
      e.semiA *
      w.geometry.supportHalfWidthMm *
      e.semiB *
      w.geometry.supportHalfLengthMm;
}

/// The sway metric table, in display order. (Window-only metrics: no
/// evaluation context beyond the window itself.)
final List<MetricDef<Object?>> swayMetrics = List.unmodifiableOf([
  const MetricDef<Object?>(
    id: 'sway_path',
    label: 'CoP path length',
    unit: 'mm',
    decimals: 0,
    compute: _pathMmNoCtx,
  ),
  const MetricDef<Object?>(
    id: 'sway_area95',
    label: '95% ellipse area',
    unit: 'mm²',
    decimals: 0,
    compute: _area95NoCtx,
  ),
  const MetricDef<Object?>(
    id: 'mean_cop_velocity',
    label: 'Mean CoP velocity',
    unit: 'mm/s',
    decimals: 1,
    compute: _meanVelocityNoCtx,
  ),
  MetricDef<Object?>(
    id: 'ml_rms',
    label: 'CoP RMS (M/L)',
    unit: 'mm',
    decimals: 2,
    compute: (w, _) => _rmsMm(w, true),
  ),
  MetricDef<Object?>(
    id: 'ap_rms',
    label: 'CoP RMS (A/P)',
    unit: 'mm',
    decimals: 2,
    compute: (w, _) => _rmsMm(w, false),
  ),
  const MetricDef<Object?>(
    id: 'left_share',
    label: 'Left load share',
    unit: '%',
    decimals: 1,
    compute: _leftShareNoCtx,
  ),
]);

// Named wrappers so the registry entries stay const: a lambda is not a
// constant, a top-level function reference is.
double? _pathMmNoCtx(PlateWindow w, Object? _) => w.copPathLengthMm;
double? _area95NoCtx(PlateWindow w, Object? _) => _area95(w);
double? _meanVelocityNoCtx(PlateWindow w, Object? _) => _meanVelocity(w);
double? _leftShareNoCtx(PlateWindow w, Object? _) => _leftShare(w);

/// Header for the ratio column of a two-window sway test: "EC/EO" for the
/// Romberg pair, a neutral fallback otherwise.
String swayRatioHeader(String? labelA, String? labelB) =>
    (labelA, labelB) == ('Eyes open', 'Eyes closed') ? 'EC/EO' : 'B/A';

/// Evaluate one sway window as the family-neutral [EvaluatedRep]: the whole
/// window is the rep, shaded faintly on the graph, with a CoP confidence
/// ellipse on the plate pane.
EvaluatedRep evaluateSwayWindow(PlateWindow w, String label, int number) {
  final eval = RepEvaluation(
    number: number,
    label: label.isEmpty ? null : label,
    start: w.start,
    end: w.end,
    values: evaluateMetrics(w, swayMetrics, null),
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
            color: const Color(0xFF2196F3),
          ),
      ],
    ),
  );
}
