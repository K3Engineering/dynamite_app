import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/utils/nice_step.dart';

void main() {
  group('niceStepCeil', () {
    test('lands on the next 1/2/5 rung at or above the target', () {
      expect(niceStepCeil(0.9), 1.0);
      expect(niceStepCeil(1.0), 1.0);
      expect(niceStepCeil(1.1), 2.0);
      expect(niceStepCeil(2.0), 2.0);
      expect(niceStepCeil(3.0), 5.0);
      expect(niceStepCeil(6.0), 10.0);
      expect(niceStepCeil(1.2), 2.0);
      expect(niceStepCeil(0.012), 0.02);
    });

    test('is scale-free: the same rungs below one', () {
      expect(niceStepCeil(0.0011), closeTo(0.002, 1e-12));
      expect(niceStepCeil(0.003), closeTo(0.005, 1e-12));
      expect(niceStepCeil(0.5), 0.5);
    });

    test('non-positive or non-finite targets throw', () {
      // No meaningful ladder rung exists for a degenerate span; drawing a
      // plausible axis for a broken fold hides the bug.
      expect(() => niceStepCeil(0), throwsArgumentError);
      expect(() => niceStepCeil(-5), throwsArgumentError);
      expect(() => niceStepCeil(double.nan), throwsArgumentError);
      expect(() => niceStepCeil(double.infinity), throwsArgumentError);
    });
  });

  group('niceStepDecimals', () {
    test('prints every rung bare of trailing zeros', () {
      // Integer rungs, including the ones whose log floor is sensitive.
      expect(niceStepDecimals(1), 0);
      expect(niceStepDecimals(2), 0);
      expect(niceStepDecimals(5), 0);
      expect(niceStepDecimals(10), 0);
      expect(niceStepDecimals(100), 0);
      expect(niceStepDecimals(0.5), 1);
      expect(niceStepDecimals(0.2), 1);
      expect(niceStepDecimals(0.02), 2);
      expect(niceStepDecimals(0.05), 2);
      // The sub-0.01 case the old fixed 2-decimal formatter printed as "0.0".
      expect(niceStepDecimals(0.002), 3);
      expect(niceStepDecimals(0.005), 3);
    });

    test('round-trips through toStringAsFixed without trailing zeros', () {
      for (final step in [0.002, 0.005, 0.02, 0.5, 2.0, 250.0]) {
        final text = step.toStringAsFixed(niceStepDecimals(step));
        if (text.contains('.')) {
          expect(text.endsWith('0'), isFalse, reason: '$step printed as $text');
        }
        expect(double.parse(text), closeTo(step, step * 1e-9));
      }
    });
  });
}
