import 'package:material_ui/material_ui.dart';

import '../analysis/metrics_isometric.dart';
import '../models/graph_overlays.dart';
import 'metric_grid.dart';

/// The isometric metric × hold table. One hold = one value column.
class IsoMetricsTable extends StatelessWidget {
  const IsoMetricsTable({super.key, required this.reps});

  final List<IsoRepResult> reps;

  @override
  Widget build(BuildContext context) {
    final ratio = reps.length == 2;
    return MetricGrid(
      columns: [
        for (final r in reps) r.label.isEmpty ? 'Rep ${r.number}' : r.label,
        if (reps.length > 2) 'Mean',
        if (ratio) 'B/A',
      ],
      rows: [
        for (final def in isoMetrics)
          MetricGridRow(
            label: def.label,
            decimals: def.decimals,
            values: [
              for (final r in reps) r.metric(def.id),
              if (reps.length > 2) _mean(def.id),
              if (ratio) _ratioOf(def.id),
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

  double? _ratioOf(String id) {
    final a = reps[0].metric(id);
    final b = reps[1].metric(id);
    if (a == null || b == null || a == 0) return null;
    return b / a;
  }
}

/// Hold-window shading on the force trace.
GraphOverlays overlaysForIsoReps(List<IsoRepResult> reps) => GraphOverlays(
  spans: [
    for (final r in reps)
      GraphOverlaySpan(
        start: r.start,
        end: r.end,
        color: const Color(0x1A000000),
      ),
  ],
);
