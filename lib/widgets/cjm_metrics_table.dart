import 'package:material_ui/material_ui.dart';

import '../analysis/metrics.dart';
import '../analysis/plate_series.dart';
import '../analysis/test_result.dart';
import '../models/graph_data_source.dart';
import '../models/graph_overlays.dart';

/// A CMJ metric × rep table with per-metric means. Shared by the live runner's
/// summary and a re-opened session.
class CjmMetricsTable extends StatelessWidget {
  const CjmMetricsTable({super.key, required this.reps});

  final List<CmjRepResult> reps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.bold,
    );
    return Table(
      columnWidths: {
        0: const FlexColumnWidth(2.2),
        for (int i = 1; i <= reps.length; i++) i: const FlexColumnWidth(),
        reps.length + 1: const FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            const SizedBox.shrink(),
            for (final r in reps)
              Text(
                'Rep ${r.number}',
                style: headerStyle,
                textAlign: TextAlign.end,
              ),
            Text('Mean', style: headerStyle, textAlign: TextAlign.end),
          ],
        ),
        for (final def in cmjMetrics)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(def.label, style: theme.textTheme.bodySmall),
              ),
              for (final r in reps) _cell(context, def, r.metric(def.id)),
              _cell(context, def, _mean(def.id)),
            ],
          ),
      ],
    );
  }

  double? _mean(String id) {
    final values = [for (final r in reps) ?r.metric(id)];
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  Widget _cell(BuildContext context, CmjMetricDef def, double? value) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          value == null ? '—' : value.toStringAsFixed(def.decimals),
          textAlign: TextAlign.end,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      );
}

/// Recompute every rep's metrics for [result] against a loaded recording.
/// Empty when the plate can't be read (no plate profile, missing
/// calibration/cells) or a stored window falls outside the recording.
List<CmjRepResult> evaluateTestResult(TestResult result, GraphDataSource data) {
  final reader = PlateReader.tryForData(data);
  if (reader == null) return const [];
  final reps = <CmjRepResult>[];
  for (int i = 0; i < result.reps.length; i++) {
    final phases = result.reps[i];
    if (phases.onset < data.oldestSample || phases.end > data.totalSamples) {
      continue;
    }
    final window = PlateWindow.capture(reader, phases.onset, phases.end);
    reps.add(
      CmjRepResult(
        number: i + 1,
        phases: phases,
        metrics: evaluateCmjMetrics(
          window,
          phases,
          CmjContext(bwKgf: result.bodyWeightKgf),
        ),
      ),
    );
  }
  return reps;
}

/// Phase shading for every rep in [result].
GraphOverlays overlaysForTestResult(TestResult result) => GraphOverlays(
  spans: [
    for (final phases in result.reps)
      for (final s in phases.spans)
        GraphOverlaySpan(
          start: s.start,
          end: s.end,
          color: cmjPhaseColor(s.label),
        ),
  ],
);
