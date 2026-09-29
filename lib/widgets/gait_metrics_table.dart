import 'package:material_ui/material_ui.dart';

import '../analysis/gait.dart';
import '../models/graph_overlays.dart';
import 'metric_grid.dart';

/// The gait metric × pass table with a mean column. Shared by the live
/// runner's summary and a re-opened session.
class GaitMetricsTable extends StatelessWidget {
  const GaitMetricsTable({super.key, required this.reps});

  final List<GaitPassResult> reps;

  @override
  Widget build(BuildContext context) {
    return MetricGrid(
      columns: [for (final r in reps) 'Pass ${r.number}', 'Mean'],
      rows: [
        for (final def in gaitMetrics)
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

/// A gait-line polyline per pass on the 2D plate pane, with matching window
/// shading on the force trace.
GraphOverlays overlaysForGaitReps(List<GaitPassResult> reps) => GraphOverlays(
  spans: [
    for (final r in reps)
      GraphOverlaySpan(
        start: r.start,
        end: r.end,
        color: const Color(0x1A000000),
      ),
  ],
  plateTrails: [
    for (final r in reps)
      PlateTrailOverlay(points: r.trail, color: gaitTrailColor(r.number)),
  ],
);
