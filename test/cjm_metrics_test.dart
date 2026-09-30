import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/events.dart';
import 'package:dynamite_app/analysis/metric_eval.dart';
import 'package:dynamite_app/analysis/metrics.dart';
import 'package:dynamite_app/analysis/segmentation_cmj.dart';

import 'helpers/synthetic_plate.dart';

void main() {
  group('jump metrics', () {
    late List<MetricValue> values;
    late Map<String, double?> byId;

    setUp(() {
      final jump = SyntheticCmj();
      final window = jump.window;
      final baseline = estimateBaseline(window, 0, jump.quietEnd)!;
      final seg =
          segmentCmj(window, JumpContext.fromBaseline(baseline)) as CmjRep;
      final ctx = CmjContext(bwKgf: baseline.meanKgf);
      values = evaluateMetrics(window, cmjMetrics, (
        phases: seg.phases,
        ctx: ctx,
      ));
      byId = {for (final v in values) v.def.id: v.value};
    });

    test('covers every registered metric exactly once', () {
      expect(values.length, cmjMetrics.length);
      expect(byId.length, cmjMetrics.length);
    });

    test('both height methods agree on a consistent jump', () {
      final flight = byId['height_flight']!;
      final impulse = byId['height_impulse']!;
      expect(flight, greaterThan(0.05));
      expect((impulse - flight).abs() / flight, lessThan(0.15));
    });

    test('height delta is small for a consistent jump', () {
      expect(byId['height_delta']!.abs(), lessThan(5)); // cm
    });

    test('takeoff velocity matches the flight time it produced', () {
      final v = byId['takeoff_velocity']!;
      final t = byId['flight_time']! / 1000;
      expect(v, greaterThan(0));
      expect(v, closeTo(9.80665 * t / 2, 0.1));
    });

    test('peak force and landing peak track the scripted profile', () {
      // Peaks are reported on the smoothed envelope, so the scripted ramp's
      // corner is rounded by roughly the smoothing window.
      expect(byId['peak_force']!, closeTo(2.8 * 80, 12));
      expect(byId['peak_landing_force']!, closeTo(2.4 * 80, 12));
    });

    test('left/right asymmetry matches the scripted shares', () {
      expect(byId['lr_asymmetry']!, closeTo(100 * 0.10 / 0.55, 1.0));
    });

    test('RFD and both phase durations are present', () {
      expect(byId['rfd_0_100'], isNotNull);
      expect(byId['eccentric_duration']!, greaterThan(0));
      expect(byId['concentric_duration']!, greaterThan(0));
    });
  });

  group('squat jump metrics', () {
    test('eccentric duration is absent and heights still agree', () {
      final jump = SyntheticCmj(dip: false);
      final window = jump.window;
      final baseline = estimateBaseline(window, 0, jump.quietEnd)!;
      final rep =
          segmentCmj(window, JumpContext.fromBaseline(baseline)) as CmjRep;
      final byId = {
        for (final v in evaluateMetrics(window, cmjMetrics, (
          phases: rep.phases,
          ctx: CmjContext(bwKgf: baseline.meanKgf),
        )))
          v.def.id: v.value,
      };
      expect(byId['eccentric_duration'], isNull);
      final flight = byId['height_flight']!;
      expect(flight, greaterThan(0.05));
      expect((byId['height_impulse']! - flight).abs() / flight, lessThan(0.15));
    });
  });

  group('eccentricUtilizationRatio', () {
    CmjRepResult repResult({required bool dip, int number = 1}) {
      final jump = SyntheticCmj(dip: dip);
      final window = jump.window;
      final baseline = estimateBaseline(window, 0, jump.quietEnd)!;
      final rep =
          segmentCmj(window, JumpContext.fromBaseline(baseline)) as CmjRep;
      return buildCmjRepResult(
        window,
        rep.phases,
        rep.jumpClass,
        CmjContext(bwKgf: baseline.meanKgf),
        number,
      );
    }

    test('is cmj height over sj height when both classes are present', () {
      final cmj = repResult(dip: true);
      final sj = repResult(dip: false, number: 2);
      final eur = eccentricUtilizationRatio([cmj, sj])!;
      expect(
        eur,
        closeTo(
          cmj.metric('height_flight')! / sj.metric('height_flight')!,
          0.001,
        ),
      );
    });

    test('is null when a class is missing', () {
      expect(eccentricUtilizationRatio([repResult(dip: true)]), isNull);
      expect(eccentricUtilizationRatio([repResult(dip: false)]), isNull);
    });
  });
}
