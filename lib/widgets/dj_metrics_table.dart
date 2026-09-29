import 'package:material_ui/material_ui.dart';

import '../analysis/plate_series.dart';
import '../analysis/segmentation_dj.dart';
import '../analysis/test_result.dart';
import '../models/graph_data_source.dart';
import '../models/graph_overlays.dart';
import 'metric_grid.dart';

/// The drop-jump metric × rep table with a mean column. Shared by the live
/// runner's summary and a re-opened session.
class DjMetricsTable extends StatelessWidget {
  const DjMetricsTable({super.key, required this.reps});

  final List<DjRepResult> reps;

  @override
  Widget build(BuildContext context) {
    return MetricGrid(
      columns: [for (final r in reps) 'Rep ${r.number}', 'Mean'],
      rows: [
        for (final def in djMetrics)
          MetricGridRow(
            label: def.label,
            decimals: def.decimals,
            values: [for (final r in reps) r.metric(def.id), _mean(def.id)],
          ),
      ],
    );
  }

  double? _mean(String id) {
    final values = [for (final r in reps) ?r.metric(id)];
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }
}

/// Recompute every rep's metrics for [result] against a loaded recording.
/// Empty when the plate can't be read or a stored window falls outside it.
List<DjRepResult> evaluateDjResult(TestResult result, GraphDataSource data) {
  final reader = PlateReader.tryForData(data);
  if (reader == null) return const [];
  final reps = <DjRepResult>[];
  for (int i = 0; i < result.reps.length; i++) {
    final rep = result.reps[i];
    final phases = DjPhases.tryFromSpans(rep);
    if (phases == null) continue;
    if (rep.start < data.oldestSample || rep.end > data.totalSamples) {
      continue;
    }
    reps.add(
      DjRepResult(
        number: i + 1,
        phases: phases,
        metrics: evaluateDjMetrics(
          PlateWindow.capture(reader, rep.start, rep.end),
          phases,
        ),
      ),
    );
  }
  return reps;
}

/// Phase shading for every rep in [result].
GraphOverlays overlaysForDjReps(List<DjRepResult> reps) => GraphOverlays(
  spans: [
    for (final r in reps)
      for (final s in r.phases.spans)
        GraphOverlaySpan(
          start: s.start,
          end: s.end,
          color: cmjPhaseColor(s.label),
        ),
  ],
);
