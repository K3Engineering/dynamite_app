import 'package:material_ui/material_ui.dart';

import '../analysis/test_family.dart';
import 'metric_grid.dart';

/// The metric × rep table shared by every test family: one column per rep
/// (its label, or "Rep n"), computed trailing columns, and freeform extra
/// rows. It renders a [RepTableSpec], which the family descriptor builds — so
/// this widget knows nothing about families and the analysis core imports no
/// widgets.
class MetricsTable extends StatelessWidget {
  const new({super.key, required this.spec});

  final RepTableSpec spec;

  @override
  Widget build(BuildContext context) {
    return MetricGrid(
      columns: [
        for (int i = 0; i < spec.reps.length; i++)
          spec.columnLabels?[i] ??
              spec.reps[i].label ??
              'Rep ${spec.reps[i].number}',
        for (final t in spec.trailing) t.header,
      ],
      rows: [
        for (final def in spec.metrics)
          MetricGridRow(
            label: def.label,
            unit: def.unit,
            decimals: def.decimals,
            values: [
              for (final r in spec.reps) r.metric(def.id),
              for (final t in spec.trailing) t.valueFor(def.id),
            ],
          ),
        for (final row in spec.extraRows)
          MetricGridRow(
            label: row.label,
            unit: row.unit,
            decimals: row.decimals,
            values: row.values,
          ),
      ],
    );
  }
}
