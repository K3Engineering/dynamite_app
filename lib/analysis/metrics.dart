import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'metric_eval.dart';
import 'plate_series.dart';
import 'result_overlays.dart';
import 'segmentation_cmj.dart';
import 'test_family.dart';

// ---------------------------------------------------------------------------
// CMJ metric registry
//
// Each metric is a pure function of a captured window, its phase boundaries
// and the baseline context, so the same definitions serve the live runner and
// a re-opened session. Jump height is reported two independent ways (flight
// time, and impulse integration of the net force) plus their difference: the
// agreement is the plate's own credibility check.
// ---------------------------------------------------------------------------

/// Baseline facts metrics need that segmentation does not, plus the one
/// integration every impulse-based metric shares. The takeoff velocity is
/// derived from the window on demand rather than stored, so a context stays
/// a plain value.
@immutable
class CmjContext {
  const new({required this.bwKgf, this.gravity = 9.80665});

  /// Body weight as the baseline read it, in kgf.
  final double bwKgf;

  /// Standard gravity (m/s²).
  final double gravity;

  /// COM velocity at takeoff (m/s), from the net-force integral over the
  /// ground phase ([_takeoffVelocity]).
  double takeoffVelocity(PlateWindow w, CmjPhases p) =>
      _takeoffVelocity(w, p, this);
}

/// Evaluation context of the jump metrics: the segmented phases plus the
/// baseline facts.
typedef CmjMetricEnv = ({CmjPhases phases, CmjContext ctx});

/// Class label for display ("CMJ" / "SJ").
String jumpClassLabel(JumpClass cls) => switch (cls) {
  JumpClass.countermovement => 'CMJ',
  JumpClass.squat => 'SJ',
};

/// Eccentric utilization ratio: mean CMJ height over mean SJ height (flight-
/// time heights), or null when either class has no measured height. Jumping
/// with a countermovement typically beats jumping from a dead hold, so a fit
/// athlete lands a bit above 1.
///
/// Reads the label a rep persists ([jumpClassLabel]), so it serves a live rep
/// and one re-read from a recording alike.
double? eccentricUtilizationRatio(List<EvaluatedRep> reps) {
  double meanHeight(String label) {
    double sum = 0;
    int n = 0;
    for (final r in reps) {
      if (r.eval.label != label) continue;
      final h = r.metric('height_flight');
      if (h == null) continue;
      sum += h;
      n++;
    }
    return n == 0 ? double.nan : sum / n;
  }

  final cmj = meanHeight(jumpClassLabel(JumpClass.countermovement));
  final sj = meanHeight(jumpClassLabel(JumpClass.squat));
  if (sj.isNaN || cmj.isNaN || sj == 0) return null;
  return cmj / sj;
}

/// The jump metric table, in display order.
final List<MetricDef<CmjMetricEnv>> cmjMetrics = List.unmodifiableOf([
  MetricDef<CmjMetricEnv>(
    id: 'height_flight',
    label: 'Jump height (flight)',
    unit: 'm',
    decimals: 3,
    compute: (w, e) {
      final t = e.phases.flightSeconds;
      return e.ctx.gravity * t * t / 8;
    },
  ),
  MetricDef<CmjMetricEnv>(
    id: 'height_impulse',
    label: 'Jump height (impulse)',
    unit: 'm',
    decimals: 3,
    compute: (w, e) {
      final v = e.ctx.takeoffVelocity(w, e.phases);
      return v * v / (2 * e.ctx.gravity);
    },
  ),
  MetricDef<CmjMetricEnv>(
    id: 'height_delta',
    label: 'Height Δ (impulse − flight)',
    unit: 'cm',
    decimals: 1,
    compute: (w, e) => (_impulseHeight(w, e) - _flightHeight(e)) * 100,
  ),
  MetricDef<CmjMetricEnv>(
    id: 'takeoff_velocity',
    label: 'Takeoff velocity',
    unit: 'm/s',
    decimals: 2,
    compute: (w, e) => e.ctx.takeoffVelocity(w, e.phases),
  ),
  MetricDef<CmjMetricEnv>(
    id: 'flight_time',
    label: 'Flight time',
    unit: 'ms',
    decimals: 0,
    compute: (w, e) => e.phases.flightSeconds * 1000,
  ),
  MetricDef<CmjMetricEnv>(
    id: 'eccentric_duration',
    label: 'Eccentric duration',
    unit: 'ms',
    decimals: 0,
    // A squat jump has no eccentric phase: dash, not zero.
    compute: (w, e) => e.phases.eccentricSamples == 0
        ? null
        : e.phases.eccentricSamples / e.phases.sampleRate * 1000,
  ),
  MetricDef<CmjMetricEnv>(
    id: 'concentric_duration',
    label: 'Concentric duration',
    unit: 'ms',
    decimals: 0,
    compute: (w, e) => e.phases.concentricSamples / e.phases.sampleRate * 1000,
  ),
  MetricDef<CmjMetricEnv>(
    id: 'peak_force',
    label: 'Peak force',
    unit: 'kgf',
    decimals: 1,
    compute: (w, e) => _peak(w, e.phases.onset, e.phases.takeoff),
  ),
  MetricDef<CmjMetricEnv>(
    id: 'peak_landing_force',
    label: 'Peak landing force',
    unit: 'kgf',
    decimals: 1,
    compute: (w, e) => _peak(w, e.phases.landing, e.phases.end - 1),
  ),
  MetricDef<CmjMetricEnv>(
    id: 'propulsion_impulse',
    label: 'Net propulsion impulse',
    unit: 'kgf·s',
    decimals: 2,
    compute: (w, e) =>
        _netImpulse(w, e.phases.onset, e.phases.takeoff, e.ctx.bwKgf),
  ),
  MetricDef<CmjMetricEnv>(
    id: 'rfd_peak_50',
    label: 'Max sustained RFD (50 ms)',
    unit: 'kgf/s',
    decimals: 0,
    compute: (w, e) => _peakRfd(w, e.phases, 50),
  ),
  MetricDef<CmjMetricEnv>(
    id: 'rfd_peak_100',
    label: 'Max sustained RFD (100 ms)',
    unit: 'kgf/s',
    decimals: 0,
    compute: (w, e) => _peakRfd(w, e.phases, 100),
  ),
  MetricDef<CmjMetricEnv>(
    id: 'lr_asymmetry',
    label: 'L/R asymmetry',
    unit: '%',
    decimals: 1,
    compute: (w, e) => _lrAsymmetry(w, e.phases),
  ),
]);

/// Jump height from the impulse-momentum takeoff velocity.
double _impulseHeight(PlateWindow w, CmjMetricEnv e) {
  final v = e.ctx.takeoffVelocity(w, e.phases);
  return v * v / (2 * e.ctx.gravity);
}

/// Jump height from flight time.
double _flightHeight(CmjMetricEnv e) =>
    e.ctx.gravity * e.phases.flightSeconds * e.phases.flightSeconds / 8;

/// Evaluate one rep: phases, class, and every metric in [cmjMetrics], as the
/// family-neutral [EvaluatedRep] the runner and the session reader both keep.
EvaluatedRep buildCmjRep(
  PlateWindow w,
  CmjPhases phases,
  CmjContext ctx,
  int number,
) {
  // The class is a fact of the phases: a squat jump has no eccentric span.
  final jumpClass = phases.eccentricSamples > 0
      ? JumpClass.countermovement
      : JumpClass.squat;
  return EvaluatedRep(
    eval: RepEvaluation(
      number: number,
      label: jumpClassLabel(jumpClass),
      start: phases.onset,
      end: phases.end,
      values: evaluateMetrics(w, cmjMetrics, (phases: phases, ctx: ctx)),
    ),
    spans: phases.spans,
    overlays: jumpPhaseOverlays(phases.spans),
  );
}

/// COM velocity at takeoff (m/s): impulse-momentum of the raw net force from
/// the quiet onset, seeded at rest. Below body weight the net force is
/// negative (the countermovement), so the integral dips then climbs on the
/// way up — the value at takeoff is what carries the athlete off the plate.
double _takeoffVelocity(PlateWindow w, CmjPhases p, CmjContext c) {
  final dt = 1 / w.sampleRate;
  double v = 0;
  for (int i = p.onset; i <= p.takeoff; i++) {
    v += c.gravity * (w.forceAt(i) / c.bwKgf - 1) * dt;
  }
  return v;
}

/// Maximum total force over `[start, end]` inclusive (raw).
double _peak(PlateWindow w, int start, int end) {
  double max = double.negativeInfinity;
  for (int i = start; i <= end; i++) {
    final f = w.forceAt(i);
    if (f > max) max = f;
  }
  return max;
}

/// Net impulse (kgf·s) of `force − bw` over `[start, end]` (raw).
double _netImpulse(PlateWindow w, int start, int end, double bw) {
  double acc = 0;
  for (int i = start; i <= end; i++) {
    acc += w.forceAt(i) - bw;
  }
  return acc / w.sampleRate;
}

/// Peak sustained RFD: the steepest [windowMs] stretch of the force rise,
/// `max over [onset, takeoff] of (F(t + windowMs) − F(t)) / windowMs` on raw
/// force. Window-averaged on purpose, unlike the instantaneous max slope —
/// at 1 kHz the latter picks ms-scale catch transients (shoe/plate/bench
/// stiffness) rather than sustained force production. Null when ground
/// contact is shorter than the window.
double? _peakRfd(PlateWindow w, CmjPhases p, int windowMs) {
  final offset = (windowMs * w.sampleRate / 1000).round();
  if (p.takeoff - p.onset < offset) return null;
  final seconds = offset / w.sampleRate;
  double best = double.negativeInfinity;
  for (int i = p.onset; i + offset <= p.takeoff; i++) {
    final slope = (w.forceAt(i + offset) - w.forceAt(i)) / seconds;
    if (slope > best) best = slope;
  }
  return best;
}

/// Left/right asymmetry of the propulsive load: `|L − R| / max(L, R)` as a
/// percentage, from the force integral over the ground phase.
double? _lrAsymmetry(PlateWindow w, CmjPhases p) {
  double left = 0, right = 0;
  for (int i = p.onset; i <= p.takeoff; i++) {
    left += w.leftAt(i);
    right += w.rightAt(i);
  }
  final max = math.max(left, right);
  if (max <= 0) return null;
  return 100 * (left - right).abs() / max;
}
