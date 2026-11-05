import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../utils/nice_step.dart';

/// Whether the comparison pane plots deviations or their regression residuals.
enum ComparisonPlotMode { total, residual }

/// Inclusive numeric limits for a comparison axis or data set.
@immutable
final class ValueBounds {
  const new(this.min, this.max);

  final double min;
  final double max;

  double get span => max - min;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ValueBounds && min == other.min && max == other.max;

  @override
  int get hashCode => Object.hash(min, max);
}

/// One paired load-cell sample: [deviation] is channel B minus channel A at
/// load [x], which is channel A's load.
typedef ComparisonPoint = ({double x, double deviation});

/// Least-squares line describing deviation as
/// `offset + gainMismatch * x + residual`.
final class ComparisonLinearFit {
  const new({required this.offset, required this.gainMismatch});

  final double offset;
  final double gainMismatch;

  double residualAt(double x, double deviation) =>
      deviation - (offset + gainMismatch * x);
}

/// Statistics for the finite points in a comparison selection.
final class ComparisonAnalysis {
  const new({
    required this.count,
    required this.x,
    required this.deviation,
    this.fit,
    this.residualBounds,
  });

  final int count;
  final ValueBounds x;
  final ValueBounds deviation;

  /// Null when every selected point has the same X (including one point).
  final ComparisonLinearFit? fit;

  /// Exact residual extrema, or null when [fit] is null.
  final ValueBounds? residualBounds;
}

/// Analyzes B-minus-A deviations against A. Non-finite pairs are ignored;
/// [points] must be replayable because residuals require a second iteration.
///
/// Welford's centered updates avoid the catastrophic cancellation of
/// `sum(x * x) - sum(x) * sum(x) / n` when loads have a large common offset.
ComparisonAnalysis? analyzeComparison(Iterable<ComparisonPoint> points) {
  var count = 0;
  var meanX = 0.0;
  var meanDeviation = 0.0;
  var xVariation = 0.0;
  var covariance = 0.0;
  var minX = double.infinity;
  var maxX = double.negativeInfinity;
  var minDeviation = double.infinity;
  var maxDeviation = double.negativeInfinity;

  for (final point in points) {
    if (!point.x.isFinite || !point.deviation.isFinite) continue;
    count++;
    final dx = point.x - meanX;
    meanX += dx / count;
    meanDeviation += (point.deviation - meanDeviation) / count;
    xVariation += dx * (point.x - meanX);
    covariance += dx * (point.deviation - meanDeviation);
    minX = math.min(minX, point.x);
    maxX = math.max(maxX, point.x);
    minDeviation = math.min(minDeviation, point.deviation);
    maxDeviation = math.max(maxDeviation, point.deviation);
  }

  if (count == 0) return null;

  ComparisonLinearFit? fit;
  ValueBounds? residualBounds;
  if (xVariation != 0) {
    final gainMismatch = covariance / xVariation;
    fit = .new(
      offset: meanDeviation - gainMismatch * meanX,
      gainMismatch: gainMismatch,
    );

    var minResidual = double.infinity;
    var maxResidual = double.negativeInfinity;
    for (final point in points) {
      if (!point.x.isFinite || !point.deviation.isFinite) continue;
      final residual = fit.residualAt(point.x, point.deviation);
      minResidual = math.min(minResidual, residual);
      maxResidual = math.max(maxResidual, residual);
    }
    residualBounds = .new(minResidual, maxResidual);
  }

  return .new(
    count: count,
    x: .new(minX, maxX),
    deviation: .new(minDeviation, maxDeviation),
    fit: fit,
    residualBounds: residualBounds,
  );
}

/// X bounds with zero included, 5% padding at each end, and limits rounded
/// out to a 1/2/5 tick grid. A zero-width selection is scaled by [quantum].
ValueBounds autoComparisonX(
  ComparisonAnalysis analysis, {
  required double quantum,
}) {
  _requirePositiveFinite(quantum, 'quantum');
  final min = math.min(0.0, analysis.x.min);
  final max = math.max(0.0, analysis.x.max);
  final span = max - min;
  final padding = (span == 0 ? quantum : span) * 0.05;
  final paddedMin = min - padding;
  final paddedMax = max + padding;
  final step = niceStepCeil((paddedMax - paddedMin) / 5);
  return .new(
    (paddedMin / step).floor() * step,
    (paddedMax / step).ceil() * step,
  );
}

/// Symmetric deviation/residual limits with 10% headroom. [quantum] supplies
/// a useful plot scale when every value is zero.
ValueBounds symmetricComparisonY(
  ValueBounds values, {
  required double quantum,
}) {
  _requirePositiveFinite(quantum, 'quantum');
  final maxAbs = math.max(values.min.abs(), values.max.abs());
  final bound = niceStepCeil(maxAbs == 0 ? quantum : maxAbs * 1.1);
  return .new(-bound, bound);
}

/// Symmetric comparison bounds spanning the cell's positive full-scale load.
ValueBounds fullScaleComparisonX(double fullScale) {
  _requirePositiveFinite(fullScale, 'fullScale');
  return .new(-fullScale, fullScale);
}

double _requirePositiveFinite(double value, String name) {
  if (!value.isFinite || value <= 0) {
    throw ArgumentError.value(value, name, 'must be finite and positive');
  }
  return value;
}
