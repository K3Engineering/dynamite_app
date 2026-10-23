import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/metrics_sway.dart';

import 'helpers/synthetic_plate.dart';

void main() {
  /// Bench support half-extents (see [kPlateGeometry]).
  const halfW = 222.25;
  const halfL = 304.8;

  Map<String, double?> byId(SwayRepResult rep) => {
    for (final v in rep.eval.values) v.def.id: v.value,
  };

  group('linear CoP ramp', () {
    // x sweeps -0.3 .. +0.3 monotonically, y holds zero. Every metric has a
    // closed-form expectation on a noiseless trace.
    const a = 0.3;
    const n = 2000;
    late Map<String, double?> m;

    setUpAll(() {
      final rep = evaluateSwayWindow(
        SyntheticSway(
          samples: n,
          copX: (t) => -a + 2 * a * t * 1000 / (n - 1),
          copY: (_) => 0,
        ).window,
        '',
        1,
      );
      m = byId(rep);
    });

    test('path length is exactly the ramp traverse', () {
      expect(m['sway_path'], closeTo(2 * a * halfW, 0.5));
    });

    test('mean velocity is path over window duration', () {
      expect(m['mean_cop_velocity'], closeTo(2 * a * halfW / (n / 1000), 0.5));
    });

    test('M/L RMS matches the uniform ramp', () {
      expect(m['ml_rms'], closeTo(a / math.sqrt(3) * halfW, 0.5));
      expect(m['ap_rms'], closeTo(0, 0.01));
    });

    test('a degenerate line has zero ellipse area', () {
      expect(m['sway_area95'], 0);
    });

    test('left load share is 50% on a centred trace', () {
      expect(m['left_share'], closeTo(50, 0.01));
    });
  });

  group('elliptical wander', () {
    // CoP on an axis-aligned ellipse, a = 0.1 (x), b = 0.05 (y), one exact
    // period per 1000 samples so the covariance is exact: a²/2, b²/2.
    const ax = 0.1;
    const ay = 0.05;
    const periodSamples = 1000;
    late SwayRepResult rep;
    late Map<String, double?> m2;

    setUpAll(() {
      rep = evaluateSwayWindow(
        SyntheticSway(
          samples: 4 * periodSamples,
          copX: (t) => ax * math.sin(2 * math.pi * t * 1000 / periodSamples),
          copY: (t) => ay * math.cos(2 * math.pi * t * 1000 / periodSamples),
        ).window,
        '',
        1,
      );
      m2 = byId(rep);
    });

    test('RMS values match the sinusoid amplitudes', () {
      expect(m2['ml_rms'], closeTo(ax / math.sqrt(2) * halfW, 0.2));
      expect(m2['ap_rms'], closeTo(ay / math.sqrt(2) * halfL, 0.2));
    });

    test('95% ellipse area from the cloud covariance', () {
      // semi = sqrt(5.991 · amplitude²/2) per axis; area = π·semiA·semiB in
      // mm² through the support half-extents.
      final semiA = math.sqrt(kEllipseChi2_95 * ax * ax / 2) * halfW;
      final semiB = math.sqrt(kEllipseChi2_95 * ay * ay / 2) * halfL;
      expect(m2['sway_area95'], closeTo(math.pi * semiA * semiB, 1));
    });

    test('ellipse overlay geometry uses normalized support units', () {
      final e = rep.ellipse!;
      expect(e.cx, closeTo(0, 1e-3));
      expect(e.cy, closeTo(0, 1e-3));
      expect(e.semiA, closeTo(math.sqrt(kEllipseChi2_95 * ax * ax / 2), 1e-3));
      expect(e.semiB, closeTo(math.sqrt(kEllipseChi2_95 * ay * ay / 2), 1e-3));
      // Major axis along x.
      expect(e.angleRad.abs(), lessThan(1e-3));
    });
  });
}
