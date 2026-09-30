import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../models/graph_data_source.dart';
import 'metric_eval.dart';
import 'plate_series.dart';
import 'test_result.dart';

// ---------------------------------------------------------------------------
// Isometric hold metrics
//
// A timed force hold against a target band (a fraction of body weight, see
// [IsoBandSpec]). Steadiness is the point: variation around the target,
// time inside the band, and drift over the hold.
// ---------------------------------------------------------------------------

/// Band facts the metrics need: body weight and the hold band in kgf.
@immutable
class IsoContext {
  const IsoContext({
    required this.bwKgf,
    required this.bandLowKgf,
    required this.bandHighKgf,
  });

  final double bwKgf;
  final double bandLowKgf;
  final double bandHighKgf;

  /// Build from the measured body weight and the window's band spec
  /// ([IsoBandSpec] fractions of body weight).
  factory IsoContext.forBw(
    double bwKgf,
    double centerFractionOfBw,
    double halfWidthFraction,
  ) => IsoContext(
    bwKgf: bwKgf,
    bandLowKgf: bwKgf * (centerFractionOfBw - halfWidthFraction),
    bandHighKgf: bwKgf * (centerFractionOfBw + halfWidthFraction),
  );
}

/// The isometric metric table, in display order.
final List<MetricDef<IsoContext>> isoMetrics = List.unmodifiable([
  MetricDef<IsoContext>(
    id: 'mean_force',
    label: 'Mean force',
    unit: 'kgf',
    decimals: 1,
    compute: (w, c) => _meanForce(w),
  ),
  MetricDef<IsoContext>(
    id: 'peak_force',
    label: 'Peak force',
    unit: 'kgf',
    decimals: 1,
    compute: (w, c) => _peak(w),
  ),
  const MetricDef<IsoContext>(
    id: 'cv',
    label: 'Steadiness (CV)',
    unit: '%',
    decimals: 2,
    compute: _cvPercent,
  ),
  const MetricDef<IsoContext>(
    id: 'time_in_band',
    label: 'Time in band',
    unit: '%',
    decimals: 1,
    compute: _timeInBand,
  ),
  const MetricDef<IsoContext>(
    id: 'drift',
    label: 'Drift rate',
    unit: 'kgf/s',
    decimals: 2,
    compute: _drift,
  ),
]);

double _meanForce(PlateWindow w) {
  double sum = 0;
  for (int i = w.start; i < w.end; i++) {
    sum += w.forceAt(i);
  }
  return sum / w.length;
}

double _peak(PlateWindow w) {
  double max = double.negativeInfinity;
  for (int i = w.start; i < w.end; i++) {
    max = math.max(max, w.forceAt(i));
  }
  return max;
}

/// Coefficient of variation of the total force: σ over mean, as a
/// percentage. Lower is steadier.
double? _cvPercent(PlateWindow w, IsoContext c) {
  final mean = _meanForce(w);
  if (mean == 0) return null;
  double sumSq = 0;
  for (int i = w.start; i < w.end; i++) {
    final d = w.forceAt(i) - mean;
    sumSq += d * d;
  }
  return 100 * math.sqrt(sumSq / w.length) / mean;
}

/// Percentage of hold samples inside the target band.
double _timeInBand(PlateWindow w, IsoContext c) {
  int inside = 0;
  for (int i = w.start; i < w.end; i++) {
    final f = w.forceAt(i);
    if (f >= c.bandLowKgf && f <= c.bandHighKgf) inside++;
  }
  return 100 * inside / w.length;
}

/// Linear-regression slope of force over the hold (kgf/s): positive = the
/// athlete crept harder, negative = fading.
double _drift(PlateWindow w, IsoContext c) {
  final n = w.length;
  if (n < 2) return 0;
  final tMean = (n - 1) / 2;
  final yMean = _meanForce(w);
  double sxy = 0, sxx = 0;
  for (int i = w.start; i < w.end; i++) {
    final t = i - w.start - tMean;
    sxy += t * (w.forceAt(i) - yMean);
    sxx += t * t;
  }
  return (sxy / sxx) * w.sampleRate;
}

/// Evaluate one hold window.
RepEvaluation evaluateIsoWindow(
  PlateWindow w,
  IsoContext ctx,
  String label,
  int number,
) => RepEvaluation(
  number: number,
  label: label.isEmpty ? null : label,
  start: w.start,
  end: w.end,
  values: evaluateMetrics(w, isoMetrics, ctx),
);

/// Recompute every hold's metrics for [result] against a loaded recording.
/// Empty when the plate can't be read or a stored window falls outside it.
/// [centerFractionOfBw]/[halfWidthFraction] come from the test definition
/// (the band is protocol, not measurement).
List<RepEvaluation> evaluateIsoResult(
  TestResult result,
  GraphDataSource data, {
  required double centerFractionOfBw,
  required double halfWidthFraction,
}) {
  final reader = PlateReader.tryForData(data);
  if (reader == null) return const [];
  final ctx = IsoContext.forBw(
    result.bodyWeightKgf,
    centerFractionOfBw,
    halfWidthFraction,
  );
  final reps = <RepEvaluation>[];
  for (int i = 0; i < result.reps.length; i++) {
    final rep = result.reps[i];
    if (rep.start < data.oldestSample || rep.end > data.totalSamples) {
      continue;
    }
    reps.add(
      evaluateIsoWindow(
        PlateWindow.capture(reader, rep.start, rep.end),
        ctx,
        rep.label ?? '',
        i + 1,
      ),
    );
  }
  return reps;
}
