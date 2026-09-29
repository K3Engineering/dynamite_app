import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'plate_series.dart';
import 'segmentation_cmj.dart';

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

typedef CmjMetricFn =
    double? Function(PlateWindow w, CmjPhases p, CmjContext c);

/// One entry in the CMJ metric table.
@immutable
class CmjMetricDef {
  const CmjMetricDef({
    required this.id,
    required this.label,
    required this.unit,
    required this.decimals,
    required this.compute,
  });

  final String id;
  final String label;

  /// Display unit symbol; empty for a dimensionless value.
  final String unit;

  /// Digits to show.
  final int decimals;

  final CmjMetricFn compute;
}

/// A computed metric value; null when the metric is not meaningful for this
/// rep (renders as a dash).
@immutable
class CmjMetricValue {
  const CmjMetricValue(this.def, this.value);
  final CmjMetricDef def;
  final double? value;
}

/// One evaluated rep: its 1-based number, its phase boundaries, and every
/// metric value. Shared by the live runner, the test summary, and a re-opened
/// session.
@immutable
class CmjRepResult {
  const CmjRepResult({
    required this.number,
    required this.phases,
    required this.metrics,
  });

  final int number;
  final CmjPhases phases;
  final List<CmjMetricValue> metrics;

  double? metric(String id) {
    for (final v in metrics) {
      if (v.def.id == id) return v.value;
    }
    return null;
  }
}

/// The CMJ metric table, in display order.
final List<CmjMetricDef> cmjMetrics = List.unmodifiable([
  CmjMetricDef(
    id: 'height_flight',
    label: 'Jump height (flight)',
    unit: 'm',
    decimals: 3,
    compute: (w, p, c) {
      final t = p.flightSeconds;
      return c.gravity * t * t / 8;
    },
  ),
  CmjMetricDef(
    id: 'height_impulse',
    label: 'Jump height (impulse)',
    unit: 'm',
    decimals: 3,
    compute: (w, p, c) {
      final v = _takeoffVelocity(w, p, c);
      return v * v / (2 * c.gravity);
    },
  ),
  CmjMetricDef(
    id: 'height_delta',
    label: 'Height Δ (impulse − flight)',
    unit: 'cm',
    decimals: 1,
    compute: (w, p, c) {
      final v = _takeoffVelocity(w, p, c);
      final impulse = v * v / (2 * c.gravity);
      final flight = c.gravity * p.flightSeconds * p.flightSeconds / 8;
      return (impulse - flight) * 100;
    },
  ),
  const CmjMetricDef(
    id: 'takeoff_velocity',
    label: 'Takeoff velocity',
    unit: 'm/s',
    decimals: 2,
    compute: _takeoffVelocity,
  ),
  CmjMetricDef(
    id: 'flight_time',
    label: 'Flight time',
    unit: 'ms',
    decimals: 0,
    compute: (w, p, c) => p.flightSeconds * 1000,
  ),
  CmjMetricDef(
    id: 'eccentric_duration',
    label: 'Eccentric duration',
    unit: 'ms',
    decimals: 0,
    compute: (w, p, c) => p.eccentricSamples / p.sampleRate * 1000,
  ),
  CmjMetricDef(
    id: 'concentric_duration',
    label: 'Concentric duration',
    unit: 'ms',
    decimals: 0,
    compute: (w, p, c) => p.concentricSamples / p.sampleRate * 1000,
  ),
  CmjMetricDef(
    id: 'peak_force',
    label: 'Peak force',
    unit: 'kgf',
    decimals: 1,
    compute: (w, p, c) => _peak(w, p.onset, p.takeoff),
  ),
  CmjMetricDef(
    id: 'peak_landing_force',
    label: 'Peak landing force',
    unit: 'kgf',
    decimals: 1,
    compute: (w, p, c) => _peak(w, p.landing, p.end - 1),
  ),
  CmjMetricDef(
    id: 'propulsion_impulse',
    label: 'Net propulsion impulse',
    unit: 'kgf·s',
    decimals: 2,
    compute: (w, p, c) => _netImpulse(w, p.onset, p.takeoff, c.bwKgf),
  ),
  const CmjMetricDef(
    id: 'rfd_0_100',
    label: 'RFD (0–100 ms)',
    unit: 'kgf/s',
    decimals: 0,
    compute: _rfd100,
  ),
  const CmjMetricDef(
    id: 'lr_asymmetry',
    label: 'L/R asymmetry',
    unit: '%',
    decimals: 1,
    compute: _lrAsymmetry,
  ),
]);

/// Evaluate every metric in [cmjMetrics] for one rep.
List<CmjMetricValue> evaluateCmjMetrics(
  PlateWindow w,
  CmjPhases p,
  CmjContext c,
) => [for (final def in cmjMetrics) CmjMetricValue(def, def.compute(w, p, c))];

/// COM velocity at takeoff (m/s): impulse-momentum of the net force from the
/// quiet onset, seeded at rest. Below body weight the net force is negative
/// (the countermovement), so the integral dips then crosses zero on the way
/// up — the value at takeoff is what carries the athlete off the plate.
double _takeoffVelocity(PlateWindow w, CmjPhases p, CmjContext c) {
  final dt = 1 / w.sampleRate;
  double v = 0;
  for (int i = p.onset; i <= p.takeoff; i++) {
    v += c.gravity * (w.smoothAt(i) / c.bwKgf - 1) * dt;
  }
  return v;
}

/// Maximum total force over `[start, end]` inclusive.
double _peak(PlateWindow w, int start, int end) {
  double max = double.negativeInfinity;
  for (int i = start; i <= end; i++) {
    final f = w.smoothAt(i);
    if (f > max) max = f;
  }
  return max;
}

/// Net impulse (kgf·s) of `force − bw` over `[start, end]`.
double _netImpulse(PlateWindow w, int start, int end, double bw) {
  double acc = 0;
  for (int i = start; i <= end; i++) {
    acc += w.smoothAt(i) - bw;
  }
  return acc / w.sampleRate;
}

/// Rate of force development over the first 100 ms of the concentric phase,
/// or null when the concentric phase is shorter than the window.
double? _rfd100(PlateWindow w, CmjPhases p, CmjContext c) {
  final offset = (0.1 * w.sampleRate).round();
  final i1 = p.bwCross + offset;
  if (i1 > p.takeoff) return null;
  return (w.smoothAt(i1) - w.smoothAt(p.bwCross)) / (offset / w.sampleRate);
}

/// Left/right asymmetry of the propulsive load: `|L − R| / max(L, R)` as a
/// percentage, from the force integral over the ground phase.
double? _lrAsymmetry(PlateWindow w, CmjPhases p, CmjContext c) {
  double left = 0, right = 0;
  for (int i = p.onset; i <= p.takeoff; i++) {
    left += w.leftAt(i);
    right += w.rightAt(i);
  }
  final max = math.max(left, right);
  if (max <= 0) return null;
  return 100 * (left - right).abs() / max;
}
