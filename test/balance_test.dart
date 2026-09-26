import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/utils/balance.dart';

void main() {
  group('PlateWeights.cop', () {
    test('full load on one corner sits at that corner', () {
      expect((tl: 0.0, tr: 10.0, bl: 0.0, br: 0.0).cop, (1.0, 1.0));
      expect((tl: 0.0, tr: 0.0, bl: 8.0, br: 0.0).cop, (-1.0, -1.0));
    });

    test('an unloaded plate has no position', () {
      expect((tl: 0.0, tr: 0.0, bl: 0.0, br: 0.0).cop, isNull);
      // Net-negative sums (tare noise) are also "no load".
      expect((tl: -1.0, tr: 0.5, bl: 0.0, br: 0.0).cop, isNull);
    });

    test('uniform loading is centered', () {
      expect((tl: 3.0, tr: 3.0, bl: 3.0, br: 3.0).cop, (0.0, 0.0));
    });
  });

  group('copSpread', () {
    /// A physically consistent plate (bilinear footprints of a point load at
    /// cop (0.2, 0.4), total 100): the edge-pair estimates agree exactly.
    const w = (tl: 28.0, tr: 42.0, bl: 12.0, br: 18.0);

    test('a consistent plate shows zero spread at any load position', () {
      final s = copSpread(w)!;
      expect(s.$1, 0.0);
      expect(s.$2, 0.0);
    });

    test('corrupting one corner opens the spread', () {
      final s = copSpread((tl: w.tl, tr: w.tr + 3, bl: w.bl, br: w.br))!;
      expect(s.$1, greaterThan(0));
      expect(s.$2, greaterThan(0));
    });

    test('an edge without load makes the spread unavailable', () {
      // All load on the top-left corner: the bottom and right edges carry
      // nothing, so no comparison is possible.
      expect(copSpread((tl: 5.0, tr: 0.0, bl: 0.0, br: 0.0)), isNull);
    });
  });

  group('balancePosition', () {
    test('ratios and signs', () {
      expect(balancePosition(2, 1), closeTo(-1 / 3, 1e-12));
      expect(balancePosition(1, 2), closeTo(1 / 3, 1e-12));
      expect(balancePosition(5, 5), 0.0);
    });

    test('no positive load has no position', () {
      expect(balancePosition(0, 0), isNull);
      expect(balancePosition(-3, 1), isNull);
    });

    test('near-cancellation clamps instead of exploding', () {
      // Both cells nearly cancel their weights: raw ratio is -199.
      expect(balancePosition(1000, -990), -1.05);
    });
  });
}
