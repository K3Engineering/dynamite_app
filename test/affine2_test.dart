import 'package:dynamite_app/widgets/graph/affine2.dart';
import 'package:flutter_test/flutter_test.dart';

void expectPoint(
  ({double x, double y}) actual,
  double x,
  double y, {
  double epsilon = 1e-9,
}) {
  expect(actual.x, closeTo(x, epsilon));
  expect(actual.y, closeTo(y, epsilon));
}

void main() {
  group('Affine2.plot', () {
    test('maps bounds into canvas coordinates with +Y down', () {
      final a = Affine2.plot(
        xMin: 10,
        xMax: 110,
        yMin: -20,
        yMax: 20,
        width: 200,
        height: 100,
      );

      expectPoint(a.project(10, -20), 0, 100);
      expectPoint(a.project(60, 0), 100, 50);
      expectPoint(a.project(110, 20), 200, 0);
      expect(a.canvasTransform, [
        2, 0, 0, 0, //
        0, -2.5, 0, 0,
        0, 0, 1, 0,
        -20, 50, 0, 1,
      ]);
    });

    test('offset and linear detrend produce the expected gain and shear', () {
      final a = Affine2.plot(
        xMin: 0,
        xMax: 100,
        yMin: -10,
        yMax: 10,
        width: 200,
        height: 100,
        offset: 2,
        slope: 0.1,
      );

      // Raw y is deviation. At A=25, displayedY = 3 - 2 - .1*25 = -1.5.
      expectPoint(a.project(25, 3), 50, 57.5);
      expect(a.xx, 2);
      expect(a.xy, 0);
      expect(a.yx, 0.5);
      expect(a.yy, -5);
      expect(a.tx, 0);
      expect(a.ty, 60);
    });

    test('rejects non-finite values, empty ranges and non-positive size', () {
      Affine2 valid() => Affine2.plot(
        xMin: 0,
        xMax: 1,
        yMin: 0,
        yMax: 1,
        width: 10,
        height: 10,
      );

      expect(valid, returnsNormally);
      expect(
        () => Affine2.plot(
          xMin: 0,
          xMax: 0,
          yMin: 0,
          yMax: 1,
          width: 10,
          height: 10,
        ),
        throwsArgumentError,
      );
      expect(
        () => Affine2.plot(
          xMin: 0,
          xMax: 1,
          yMin: 0,
          yMax: double.nan,
          width: 10,
          height: 10,
        ),
        throwsArgumentError,
      );
      expect(
        () => Affine2.plot(
          xMin: 0,
          xMax: 1,
          yMin: 0,
          yMax: 1,
          width: 0,
          height: 10,
        ),
        throwsArgumentError,
      );
      expect(
        () => Affine2.plot(
          xMin: 0,
          xMax: 1,
          yMin: 0,
          yMax: 1,
          width: 10,
          height: 10,
          slope: double.infinity,
        ),
        throwsArgumentError,
      );
    });
  });

  test('compose applies the inner transform first and inverse round-trips', () {
    const inner = Affine2(xx: 2, xy: 0.25, yx: -0.5, yy: 3, tx: 7, ty: -11);
    final outer = Affine2.plot(
      xMin: -20,
      xMax: 30,
      yMin: -10,
      yMax: 40,
      width: 300,
      height: 125,
      offset: 4,
      slope: -0.2,
    );
    final composite = outer.compose(inner);

    final innerPoint = inner.project(8, -3);
    final expected = outer.project(innerPoint.x, innerPoint.y);
    expectPoint(composite.project(8, -3), expected.x, expected.y);
    final p = composite.project(8, -3);
    expectPoint(composite.inverse.project(p.x, p.y), 8, -3);
    expect(
      () => const Affine2(xx: 1, xy: 2, yx: 2, yy: 4, tx: 0, ty: 0).inverse,
      throwsStateError,
    );
  });

  group('Affine2.covers', () {
    final old = Affine2.plot(
      xMin: 0,
      xMax: 100,
      yMin: -10,
      yMax: 10,
      width: 200,
      height: 100,
    );

    test('a zoomed-in current view is wholly contained in the old bake', () {
      final current = Affine2.plot(
        xMin: 25,
        xMax: 75,
        yMin: -4,
        yMax: 6,
        width: 200,
        height: 100,
      );
      expect(old.covers(current, 200, 100), isTrue);
      expect(current.covers(old, 200, 100), isFalse);
    });

    test('a zoomed-out current view needs pixels the old bake clipped', () {
      final current = Affine2.plot(
        xMin: -50,
        xMax: 150,
        yMin: -20,
        yMax: 20,
        width: 200,
        height: 100,
      );
      expect(old.covers(current, 200, 100), isFalse);
    });
  });
}
