import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/events.dart';
import 'package:dynamite_app/analysis/metrics.dart';
import 'package:dynamite_app/analysis/segmentation_cmj.dart';

import 'helpers/synthetic_plate.dart';

void main() {
  group('evaluateCmjMetrics', () {
    late List<CmjMetricValue> values;
    late Map<String, double?> byId;

    setUp(() {
      final jump = SyntheticCmj();
      final window = jump.window;
      final baseline = estimateBaseline(window, 0, jump.quietEnd)!;
      final seg =
          segmentCmj(window, JumpContext.fromBaseline(baseline)) as CmjRep;
      final ctx = CmjContext(bwKgf: baseline.meanKgf);
      values = evaluateCmjMetrics(window, seg.phases, ctx);
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
}
