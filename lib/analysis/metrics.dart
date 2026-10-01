import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../models/graph_data_source.dart';
import 'metric_eval.dart';
import 'plate_series.dart';
import 'segmentation_cmj.dart';
import 'test_result.dart';

// ---------------------------------------------------------------------------
// CMJ metric registry
//
// Each metric is a pure function of a captured window, its phase boundaries
// and the baseline context, so the same definitions serve the live runner and
// a re-opened session. Jump height is reported two independent ways (flight
// time, and impulse integration of the net force) plus their difference: the
// agreement is the plate's own credibility check.
// ---------------------------------------------------------------------------

/// Baseline facts metrics need that segmentation does not.
@immutable
class CmjContext {
  const CmjContext({required this.bwKgf, this.gravity = 9.80665});

  /// Body weight as the baseline read it, in kgf.
  final double bwKgf;

  /// Standard gravity (m/s²).
  final double gravity;
}

/// Evaluation context of the jump metrics: the segmented phases plus the
/// baseline facts.
typedef CmjMetricEnv = ({CmjPhases phases, CmjContext ctx});

/// One evaluated rep: its evaluation (number, class label, window, metric
/// values), its classification, and its phase boundaries (overlays and
/// persistence read those straight off the phases).
@immutable
class CmjRepResult {
  const CmjRepResult({
    required this.eval,
    required this.jumpClass,
    required this.phases,
  });

  final RepEvaluation eval;
  final JumpClass jumpClass;
  final CmjPhases phases;

  int get number => eval.number;

  double? metric(String id) => eval.metric(id);
}

/// Class label for display ("CMJ" / "SJ").
String jumpClassLabel(JumpClass cls) => switch (cls) {
  JumpClass.countermovement => 'CMJ',
  JumpClass.squat => 'SJ',
};

/// Eccentric utilization ratio: mean CMJ height over mean SJ height (flight-
/// time heights), or null when either class has no measured height. Jumping
/// with a countermovement typically beats jumping from a dead hold, so a fit
/// athlete lands a bit above 1.
double? eccentricUtilizationRatio(List<CmjRepResult> reps) {
  double meanHeight(JumpClass cls) {
    double sum = 0;
    int n = 0;
    for (final r in reps) {
      if (r.jumpClass != cls) continue;
      final h = r.metric('height_flight');
      if (h == null) continue;
      sum += h;
      n++;
    }
    return n == 0 ? double.nan : sum / n;
  }

  final cmj = meanHeight(JumpClass.countermovement);
  final sj = meanHeight(JumpClass.squat);
  if (sj.isNaN || cmj.isNaN || sj == 0) return null;
  return cmj / sj;
}

/// The jump metric table, in display order.
final List<MetricDef<CmjMetricEnv>> cmjMetrics = List.unmodifiable([
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
      final v = _takeoffVelocity(w, e.phases, e.ctx);
      return v * v / (2 * e.ctx.gravity);
    },
  ),
  MetricDef<CmjMetricEnv>(
    id: 'height_delta',
    label: 'Height Δ (impulse − flight)',
    unit: 'cm',
    decimals: 1,
    compute: (w, e) {
      final v = _takeoffVelocity(w, e.phases, e.ctx);
      final impulse = v * v / (2 * e.ctx.gravity);
      final flight =
          e.ctx.gravity * e.phases.flightSeconds * e.phases.flightSeconds / 8;
      return (impulse - flight) * 100;
    },
  ),
  MetricDef<CmjMetricEnv>(
    id: 'takeoff_velocity',
    label: 'Takeoff velocity',
    unit: 'm/s',
    decimals: 2,
    compute: (w, e) => _takeoffVelocity(w, e.phases, e.ctx),
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

/// Evaluate one rep: phases, class, and every metric in [cmjMetrics].
CmjRepResult buildCmjRepResult(
  PlateWindow w,
  CmjPhases phases,
  JumpClass jumpClass,
  CmjContext ctx,
  int number,
) => CmjRepResult(
  eval: RepEvaluation(
    number: number,
    label: jumpClassLabel(jumpClass),
    start: phases.onset,
    end: phases.end,
    values: evaluateMetrics(w, cmjMetrics, (phases: phases, ctx: ctx)),
  ),
  jumpClass: jumpClass,
  phases: phases,
);

/// Recompute every rep's metrics for [result] against a loaded recording.
/// Empty when the plate can't be read (no plate profile, missing
/// calibration/cells) or a stored window falls outside the recording.
List<CmjRepResult> evaluateJumpResult(TestResult result, GraphDataSource data) {
  final reader = PlateReader.tryForData(data);
  if (reader == null) return const [];
  final reps = <CmjRepResult>[];
  for (int i = 0; i < result.reps.length; i++) {
    final rep = result.reps[i];
    final phases = CmjPhases.tryFromSpans(rep, sampleRate: data.sampleRate);
    if (phases == null) continue;
    if (rep.start < data.oldestSample || rep.end > data.totalSamples) {
      continue;
    }
    final window = PlateWindow.capture(reader, rep.start, rep.end);
    reps.add(
      buildCmjRepResult(
        window,
        phases,
        // The class is a fact of the persisted spans (see [CmjPhases.spans]).
        phases.eccentricSamples > 0
            ? JumpClass.countermovement
            : JumpClass.squat,
        CmjContext(bwKgf: result.bodyWeightKgf),
        i + 1,
      ),
    );
  }
  return reps;
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
