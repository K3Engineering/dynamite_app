import 'package:dynamite_app/models/cell_comparison.dart';
import 'package:flutter_test/flutter_test.dart';

ComparisonPoint _point(double x, double deviation) =>
    (x: x, deviation: deviation);

ComparisonAnalysis _analysisForX(double min, double max) =>
    .new(count: 2, x: .new(min, max), deviation: const .new(0, 0));

void main() {
  group('ValueBounds', () {
    test('span, equality, and hash code', () {
      const bounds = ValueBounds(-2, 5);
      expect(bounds.span, 7);
      expect(bounds, const ValueBounds(-2, 5));
      expect(bounds.hashCode, const ValueBounds(-2, 5).hashCode);
      expect(bounds, isNot(const ValueBounds(-2, 6)));
    });
  });

  group('analyzeComparison', () {
    test('recovers linear gain mismatch and offset', () {
      final points = [
        for (final x in <double>[0, 10, 20, 40]) _point(x, 2.5 + 0.125 * x),
      ];
      final analysis = analyzeComparison(points)!;

      expect(analysis.count, 4);
      expect(analysis.x, const ValueBounds(0, 40));
      expect(analysis.deviation, const ValueBounds(2.5, 7.5));
      expect(analysis.fit!.offset, closeTo(2.5, 1e-12));
      expect(analysis.fit!.gainMismatch, closeTo(0.125, 1e-12));
      expect(analysis.residualBounds, const ValueBounds(0, 0));
      for (final point in points) {
        expect(
          analysis.fit!.residualAt(point.x, point.deviation),
          closeTo(0, 1e-12),
        );
      }
    });

    test('retains nonlinear shape in exact residual bounds', () {
      // d = x² has least-squares fit d = -1 + 3x on these four loads.
      final points = [
        for (final x in <double>[0, 1, 2, 3]) _point(x, x * x),
      ];
      final analysis = analyzeComparison(points)!;

      expect(analysis.fit!.offset, 0 - 1);
      expect(analysis.fit!.gainMismatch, 3);
      expect(analysis.residualBounds, const ValueBounds(-1, 1));
      expect(
        points.map((p) => analysis.fit!.residualAt(p.x, p.deviation)),
        orderedEquals(<double>[1, -1, -1, 1]),
      );
    });

    test('identical channels have a zero line and zero residuals', () {
      final analysis = analyzeComparison([
        for (final x in <double>[0, 5, 10]) _point(x, 0),
      ])!;

      expect(analysis.deviation, const ValueBounds(0, 0));
      expect(analysis.fit!.offset, 0);
      expect(analysis.fit!.gainMismatch, 0);
      expect(analysis.residualBounds, const ValueBounds(0, 0));
    });

    test('fits negative loads without reflecting either axis', () {
      final analysis = analyzeComparison([
        for (final x in <double>[-100, -75, -50, -25]) _point(x, -1 + 0.5 * x),
      ])!;

      expect(analysis.x, const ValueBounds(-100, -25));
      expect(analysis.deviation, const ValueBounds(-51, -13.5));
      expect(analysis.fit!.offset, -1);
      expect(analysis.fit!.gainMismatch, 0.5);
      expect(analysis.residualBounds, const ValueBounds(0, 0));
    });

    test('offset only produces zero gain mismatch', () {
      final analysis = analyzeComparison([
        for (final x in <double>[-5, 0, 15]) _point(x, 3.25),
      ])!;

      expect(analysis.fit!.offset, 3.25);
      expect(analysis.fit!.gainMismatch, 0);
      expect(analysis.residualBounds, const ValueBounds(0, 0));
    });

    test('same-load data has statistics but no fit or residuals', () {
      final analysis = analyzeComparison([
        _point(5, 1),
        _point(5, 2),
        _point(5, 4),
      ])!;

      expect(analysis.count, 3);
      expect(analysis.x, const ValueBounds(5, 5));
      expect(analysis.deviation, const ValueBounds(1, 4));
      expect(analysis.fit, isNull);
      expect(analysis.residualBounds, isNull);
      expect(analyzeComparison([_point(5, 1)])!.fit, isNull);
    });

    test('empty and wholly non-finite data return null', () {
      expect(analyzeComparison(const <ComparisonPoint>[]), isNull);
      expect(
        analyzeComparison([
          _point(double.nan, 1),
          _point(1, double.infinity),
          _point(double.negativeInfinity, 2),
        ]),
        isNull,
      );
    });

    test('ignores non-finite pairs while retaining valid points', () {
      final analysis = analyzeComparison([
        _point(double.nan, 100),
        _point(0, 1),
        _point(1, double.infinity),
        _point(1, 3),
      ])!;

      expect(analysis.count, 2);
      expect(analysis.fit!.offset, 1);
      expect(analysis.fit!.gainMismatch, 2);
    });

    test('centered covariance is stable around a large load offset', () {
      const base = 1e12;
      final points = [
        for (var i = 0; i < 5; i++) _point(base + i, 5 + 0.002 * i),
      ];
      final analysis = analyzeComparison(points)!;
      final fit = analysis.fit!;

      // Naive uncentered sums commonly collapse X variance to zero here.
      expect(fit.gainMismatch, closeTo(0.002, 1e-15));
      expect(fit.offset, closeTo(-1999999995, 0.001));
      for (final point in points) {
        expect(fit.residualAt(point.x, point.deviation).abs(), lessThan(2e-6));
      }
      expect(analysis.residualBounds, isNotNull);
    });
  });

  group('autoComparisonX', () {
    test('includes zero, adds padding, and rounds outward to nice ticks', () {
      expect(
        autoComparisonX(_analysisForX(20, 80), quantum: 1),
        const ValueBounds(-20, 100),
      );
    });

    test('negative-only data includes zero and headroom on both ends', () {
      expect(
        autoComparisonX(_analysisForX(-80, -20), quantum: 1),
        const ValueBounds(-100, 20),
      );
    });

    test('zero-width data gets a finite quantum-scaled span', () {
      final small = autoComparisonX(_analysisForX(0, 0), quantum: 0.25);
      final large = autoComparisonX(_analysisForX(0, 0), quantum: 2.5);

      expect(small.min, lessThan(0));
      expect(small.max, greaterThan(0));
      expect(small.span, greaterThan(0));
      expect(small.min.isFinite && small.max.isFinite, isTrue);
      expect(large.span, closeTo(small.span * 10, 1e-12));
    });

    test('quantum must be finite and positive', () {
      for (final quantum in <double>[0, -1, double.nan, double.infinity]) {
        expect(
          () => autoComparisonX(_analysisForX(0, 1), quantum: quantum),
          throwsArgumentError,
        );
      }
    });
  });

  group('symmetricComparisonY', () {
    test('uses the larger extreme, 10% headroom, and a nice ceiling', () {
      expect(
        symmetricComparisonY(const ValueBounds(-3, 8), quantum: 0.01),
        const ValueBounds(-10, 10),
      );
      expect(
        symmetricComparisonY(const ValueBounds(-12, 2), quantum: 0.01),
        const ValueBounds(-20, 20),
      );
    });

    test('zero values use a positive quantum-derived fallback', () {
      expect(
        symmetricComparisonY(const ValueBounds(0, 0), quantum: 0.03),
        const ValueBounds(-0.05, 0.05),
      );
    });

    test('quantum must be finite and positive even for nonzero data', () {
      for (final quantum in <double>[0, -1, double.nan, double.infinity]) {
        expect(
          () =>
              symmetricComparisonY(const ValueBounds(-1, 1), quantum: quantum),
          throwsArgumentError,
        );
      }
    });
  });

  group('fullScaleComparisonX', () {
    test('returns symmetric full-scale bounds', () {
      expect(fullScaleComparisonX(250), const ValueBounds(-250, 250));
      expect(fullScaleComparisonX(0.25), const ValueBounds(-0.25, 0.25));
    });

    test('rejects non-positive and non-finite full scale', () {
      for (final fullScale in <double>[
        0,
        -1,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(() => fullScaleComparisonX(fullScale), throwsArgumentError);
      }
    });
  });
}
