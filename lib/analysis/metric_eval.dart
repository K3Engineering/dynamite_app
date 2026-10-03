import 'package:meta/meta.dart';

import 'plate_series.dart';

// ---------------------------------------------------------------------------
// Shared metric plumbing for every test family
//
// One row type (metadata + computation) and one rep type (number, label,
// window, values) replace the per-family def/value/result copies. A family's
// evaluation context (jump phases, an isometric band, plain body weight)
// rides the def's type parameter, so each family keeps a typed registry
// while display and persistence see only the metadata.
// ---------------------------------------------------------------------------

/// One row of a family's metric registry: display metadata plus the pure
/// computation over a captured window and the family's evaluation context.
@immutable
class MetricDef<C> {
  const MetricDef({
    required this.id,
    required this.label,
    required this.unit,
    required this.decimals,
    required this.compute,
  });

  final String id;
  final String label;

  /// Display unit symbol; empty for a dimensionless value.
  final String unit;

  /// Digits to show.
  final int decimals;

  final double? Function(PlateWindow w, C ctx) compute;
}

/// A computed metric value; null when the metric is not meaningful for this
/// rep (renders as a dash).
@immutable
class MetricValue {
  const MetricValue(this.def, this.value);

  /// The producing definition. Typed `dynamic`: display only reads the
  /// metadata, never the context parameter.
  final MetricDef<dynamic> def;
  final double? value;
}

/// Evaluate [defs] over one window with context [ctx].
List<MetricValue> evaluateMetrics<C>(
  PlateWindow w,
  List<MetricDef<C>> defs,
  C ctx,
) => [for (final def in defs) MetricValue(def, def.compute(w, ctx))];

/// One evaluated rep of any test family: its 1-based number, a display label
/// (jump class, "Eyes open", "Left leg"; null when the test has one rep
/// kind), the analysis window, and every metric value. Shared by the live
/// runner, the test summary, and a re-opened session.
@immutable
class RepEvaluation {
  const RepEvaluation({
    required this.number,
    this.label,
    required this.start,
    required this.end,
    required this.values,
  });

  final int number;
  final String? label;

  /// Analysis window `[start, end)` in samples (window shading, overlays).
  final int start;
  final int end;

  final List<MetricValue> values;

  double? metric(String id) {
    for (final v in values) {
      if (v.def.id == id) return v.value;
    }
    return null;
  }
}
