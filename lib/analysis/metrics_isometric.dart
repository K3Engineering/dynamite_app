import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../models/graph_data_source.dart';
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

/// One entry in the isometric metric table.
@immutable
class IsoMetricDef {
  const IsoMetricDef({
    required this.id,
    required this.label,
    required this.unit,
    required this.decimals,
    required this.compute,
  });

  final String id;
  final String label;
  final String unit;
  final int decimals;

  final double? Function(PlateWindow w, IsoContext c) compute;
}

/// A computed metric value; null when not meaningful for this hold.
@immutable
class IsoMetricValue {
  const IsoMetricValue(this.def, this.value);
  final IsoMetricDef def;
  final double? value;
}

/// One evaluated hold (shared live / summary / re-opened session).
@immutable
class IsoRepResult {
  const IsoRepResult({
    required this.number,
    required this.label,
    required this.start,
    required this.end,
    required this.sampleRate,
    required this.values,
  });

  final int number;
  final String label;
  final int start;
  final int end;
  final int sampleRate;

  final List<IsoMetricValue> values;

  double? metric(String id) {
    for (final v in values) {
      if (v.def.id == id) return v.value;
    }
    return null;
  }
}

/// The isometric metric table, in display order.
final List<IsoMetricDef> isoMetrics = List.unmodifiable([
  IsoMetricDef(
    id: 'mean_force',
    label: 'Mean force',
    unit: 'kgf',
    decimals: 1,
    compute: (w, c) => _meanForce(w),
  ),
  IsoMetricDef(
    id: 'peak_force',
    label: 'Peak force',
    unit: 'kgf',
    decimals: 1,
    compute: (w, c) => _peak(w),
  ),
  const IsoMetricDef(
    id: 'cv',
    label: 'Steadiness (CV)',
    unit: '%',
    decimals: 2,
    compute: _cvPercent,
  ),
  const IsoMetricDef(
    id: 'time_in_band',
    label: 'Time in band',
    unit: '%',
    decimals: 1,
    compute: _timeInBand,
  ),
  const IsoMetricDef(
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
    sum += w.smoothAt(i);
  }
  return sum / w.length;
}

double _peak(PlateWindow w) {
  double max = double.negativeInfinity;
  for (int i = w.start; i < w.end; i++) {
    max = math.max(max, w.smoothAt(i));
  }
  return max;
}

/// Coefficient of variation of the smoothed force: σ over mean, as a
/// percentage. Lower is steadier.
double? _cvPercent(PlateWindow w, IsoContext c) {
  final mean = _meanForce(w);
  if (mean == 0) return null;
  double sumSq = 0;
  for (int i = w.start; i < w.end; i++) {
    final d = w.smoothAt(i) - mean;
    sumSq += d * d;
  }
  return 100 * math.sqrt(sumSq / w.length) / mean;
}

/// Percentage of hold samples inside the target band.
double _timeInBand(PlateWindow w, IsoContext c) {
  int inside = 0;
  for (int i = w.start; i < w.end; i++) {
    final f = w.smoothAt(i);
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
    sxy += t * (w.smoothAt(i) - yMean);
    sxx += t * t;
  }
  return (sxy / sxx) * w.sampleRate;
}

/// Evaluate one hold window.
IsoRepResult evaluateIsoWindow(
  PlateWindow w,
  IsoContext ctx,
  String label,
  int number,
) => IsoRepResult(
  number: number,
  label: label,
  start: w.start,
  end: w.end,
  sampleRate: w.sampleRate,
  values: [
    for (final def in isoMetrics) IsoMetricValue(def, def.compute(w, ctx)),
  ],
);

/// Recompute every hold's metrics for [result] against a loaded recording.
/// Empty when the plate can't be read or a stored window falls outside it.
/// [centerFractionOfBw]/[halfWidthFraction] come from the test definition
/// (the band is protocol, not measurement).
List<IsoRepResult> evaluateIsoResult(
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
  final reps = <IsoRepResult>[];
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
