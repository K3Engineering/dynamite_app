import 'package:material_ui/material_ui.dart';

import '../analysis/gait.dart';
import '../analysis/metric_eval.dart';
import '../analysis/metrics.dart';
import '../analysis/metrics_isometric.dart';
import '../analysis/metrics_single_leg.dart';
import '../analysis/metrics_sway.dart';
import '../analysis/segmentation_dj.dart';
import 'metric_grid.dart';

/// A computed trailing column (mean, ratio) appended after the per-rep
/// columns: one value per metric row, keyed by the metric's id.
@immutable
class TrailingMetricColumn {
  const TrailingMetricColumn(this.header, this.valueFor);

  final String header;
  final double? Function(String metricId) valueFor;
}

/// Mean over the reps' values, per metric id.
TrailingMetricColumn meanTrailingColumn(
  List<RepEvaluation> reps, {
  String header = 'Mean',
}) => TrailingMetricColumn(header, (id) {
  final values = [for (final r in reps) ?r.metric(id)];
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a + b) / values.length;
});

/// `b / a` per metric id (null when either side is missing or `a` is zero).
TrailingMetricColumn ratioTrailingColumn(
  String header,
  RepEvaluation a,
  RepEvaluation b,
) => TrailingMetricColumn(header, (id) {
  final x = a.metric(id);
  final y = b.metric(id);
  if (x == null || y == null || x == 0) return null;
  return y / x;
});

/// The metric × rep table shared by every test family: one column per rep
/// (its label, or "Rep n"), optional computed trailing columns, optional
/// freeform extra rows (e.g. the jump battery's EUR). Units come from the
/// metric defs. Shared by the live runner's summary and a re-opened session.
class MetricsTable extends StatelessWidget {
  const MetricsTable({
    super.key,
    required this.metrics,
    required this.reps,
    this.columnLabels,
    this.trailing = const [],
    this.extraRows = const [],
  });

  /// The jump battery's table: "Rep n (CMJ)" columns, a mean, and an EUR row
  /// when both jump classes are present.
  factory MetricsTable.jump({Key? key, required List<CmjRepResult> reps}) {
    final evals = [for (final r in reps) r.eval];
    final eur = eccentricUtilizationRatio(reps);
    return MetricsTable(
      key: key,
      metrics: cmjMetrics,
      reps: evals,
      columnLabels: [for (final r in reps) 'Rep ${r.number} (${r.eval.label})'],
      trailing: [meanTrailingColumn(evals)],
      extraRows: [
        if (eur != null)
          MetricGridRow(
            label: 'EUR (CMJ/SJ)',
            decimals: 2,
            values: [for (final _ in reps) null, eur],
          ),
      ],
    );
  }

  /// The drop-jump table with a mean column.
  factory MetricsTable.dropJump({Key? key, required List<DjRepResult> reps}) {
    final evals = [for (final r in reps) r.eval];
    return MetricsTable(
      key: key,
      metrics: djMetrics,
      reps: evals,
      trailing: [meanTrailingColumn(evals)],
    );
  }

  /// The quiet-stance table. A two-window test (Romberg) gets a ratio column
  /// instead of a meaningless cross-condition mean.
  factory MetricsTable.sway({Key? key, required List<SwayRepResult> reps}) {
    final evals = [for (final r in reps) r.eval];
    return MetricsTable(
      key: key,
      metrics: swayMetrics,
      reps: evals,
      trailing: [
        if (evals.length == 2)
          ratioTrailingColumn(
            swayRatioHeader(evals[0].label, evals[1].label),
            evals[0],
            evals[1],
          ),
      ],
    );
  }

  /// The isometric table: a ratio over two holds, a mean over more, bare
  /// values for one.
  factory MetricsTable.isometric({
    Key? key,
    required List<RepEvaluation> reps,
  }) => MetricsTable(
    key: key,
    metrics: isoMetrics,
    reps: reps,
    trailing: [
      if (reps.length == 2) ratioTrailingColumn('B/A', reps[0], reps[1]),
      if (reps.length > 2) meanTrailingColumn(reps),
    ],
  );

  /// The single-leg table (one or both legs): bare values.
  factory MetricsTable.singleLeg({Key? key, required List<SlRepResult> reps}) {
    return MetricsTable(
      key: key,
      metrics: slMetrics,
      reps: [for (final r in reps) r.eval],
    );
  }

  /// The gait table: "Pass n" columns and a mean.
  factory MetricsTable.gait({Key? key, required List<GaitPassResult> reps}) {
    final evals = [for (final r in reps) r.eval];
    return MetricsTable(
      key: key,
      metrics: gaitMetrics,
      reps: evals,
      columnLabels: [for (final r in reps) 'Pass ${r.number}'],
      trailing: [meanTrailingColumn(evals)],
    );
  }

  /// The family's metric registry, in display order.
  final List<MetricDef<dynamic>> metrics;

  /// One column per rep.
  final List<RepEvaluation> reps;

  /// Overrides the per-rep column headers ("Rep n (CMJ)", "Pass n"); the
  /// default is the rep's label, or "Rep n" when unlabeled.
  final List<String>? columnLabels;

  /// Computed columns after the per-rep ones (mean, ratio).
  final List<TrailingMetricColumn> trailing;

  /// Freeform rows appended after the metric rows (EUR).
  final List<MetricGridRow> extraRows;

  @override
  Widget build(BuildContext context) {
    return MetricGrid(
      columns: [
        for (int i = 0; i < reps.length; i++)
          columnLabels?[i] ?? reps[i].label ?? 'Rep ${reps[i].number}',
        for (final t in trailing) t.header,
      ],
      rows: [
        for (final def in metrics)
          MetricGridRow(
            label: def.label,
            unit: def.unit,
            decimals: def.decimals,
            values: [
              for (final r in reps) r.metric(def.id),
              for (final t in trailing) t.valueFor(def.id),
            ],
          ),
        ...extraRows,
      ],
    );
  }
}
