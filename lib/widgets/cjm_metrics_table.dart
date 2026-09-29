import 'package:material_ui/material_ui.dart';

import '../analysis/metrics.dart';
import '../analysis/plate_series.dart';
import '../analysis/segmentation_cmj.dart';
import '../analysis/test_result.dart';
import '../models/graph_data_source.dart';
import '../models/graph_overlays.dart';
import 'metric_grid.dart';

/// The jump battery's metric × rep table: one column per classified rep,
/// a mean column, and an EUR row when both jump classes are present. Shared
/// by the live runner's summary and a re-opened session.
class CjmMetricsTable extends StatelessWidget {
  const CjmMetricsTable({super.key, required this.reps});

  final List<CmjRepResult> reps;

  @override
  Widget build(BuildContext context) {
    final eur = eccentricUtilizationRatio(reps);
    return MetricGrid(
      columns: [
        for (final r in reps)
          'Rep ${r.number} (${jumpClassLabel(r.jumpClass)})',
        'Mean',
      ],
      rows: [
        for (final def in cmjMetrics)
          MetricGridRow(
            label: def.label,
            decimals: def.decimals,
            values: [for (final r in reps) r.metric(def.id), _mean(def.id)],
          ),
        if (eur != null)
          MetricGridRow(
            label: 'EUR (CMJ/SJ)',
            decimals: 2,
            values: [for (final _ in reps) null, eur],
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
/// Empty when the plate can't be read (no plate profile, missing
/// calibration/cells) or a stored window falls outside the recording.
List<CmjRepResult> evaluateTestResult(TestResult result, GraphDataSource data) {
  final reader = PlateReader.tryForData(data);
  if (reader == null) return const [];
  final reps = <CmjRepResult>[];
  for (int i = 0; i < result.reps.length; i++) {
    final rep = result.reps[i];
    final phases = CmjPhases.tryFromSpans(rep);
    if (phases == null) continue;
    if (rep.start < data.oldestSample || rep.end > data.totalSamples) {
      continue;
    }
    final window = PlateWindow.capture(reader, rep.start, rep.end);
    reps.add(
      CmjRepResult(
        number: i + 1,
        // The class is a fact of the persisted spans (see [CmjPhases.spans]).
        jumpClass: phases.eccentricSamples > 0
            ? JumpClass.countermovement
            : JumpClass.squat,
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
    for (final rep in result.reps)
      for (final s in rep.spans)
        GraphOverlaySpan(
          start: s.start,
          end: s.end,
          color: cmjPhaseColor(s.label),
        ),
  ],
);
