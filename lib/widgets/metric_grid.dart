import 'package:material_ui/material_ui.dart';

/// One grid row: a metric label and one value per column.
/// `values[i] == null` renders a dash in column i.
@immutable
class MetricGridRow {
  const MetricGridRow({
    required this.label,
    required this.decimals,
    required this.values,
  });

  final String label;
  final int decimals;
  final List<double?> values;
}

/// The metric × rep value grid shared by every test family. Callers build
/// columns and rows (including any computed trailing column — mean, ratio)
/// per family; this renders them.
class MetricGrid extends StatelessWidget {
  const MetricGrid({super.key, required this.columns, required this.rows});

  /// Column headers, e.g. 'Rep 1 (CMJ)'; [MetricGridRow.values] must match.
  final List<String> columns;
  final List<MetricGridRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.bold,
    );
    return Table(
      columnWidths: {
        0: const FlexColumnWidth(2.2),
        for (int i = 1; i <= columns.length; i++) i: const FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            const SizedBox.shrink(),
            for (final c in columns)
              Text(c, style: headerStyle, textAlign: TextAlign.end),
          ],
        ),
        for (final row in rows)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(row.label, style: theme.textTheme.bodySmall),
              ),
              for (final v in row.values) _cell(context, row.decimals, v),
            ],
          ),
      ],
    );
  }

  Widget _cell(BuildContext context, int decimals, double? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(
      value == null ? '—' : value.toStringAsFixed(decimals),
      textAlign: TextAlign.end,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}
