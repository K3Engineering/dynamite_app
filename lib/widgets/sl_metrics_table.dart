import 'package:material_ui/material_ui.dart';

import '../analysis/metrics_single_leg.dart';
import '../models/graph_overlays.dart';
import 'metric_grid.dart';

/// The single-leg metric × hold table (one or both legs).
class SlMetricsTable extends StatelessWidget {
  const SlMetricsTable({super.key, required this.reps});

  final List<SlRepResult> reps;

  @override
  Widget build(BuildContext context) {
    return MetricGrid(
      columns: [
        for (final r in reps) r.label.isEmpty ? 'Rep ${r.number}' : r.label,
      ],
      rows: [
        for (final def in slMetrics)
          MetricGridRow(
            label: def.label,
            decimals: def.decimals,
            values: [for (final r in reps) r.metric(def.id)],
          ),
      ],
    );
  }
}

/// Interval shading on the force trace plus a CoP ellipse per hold on the
/// 2D plate pane.
GraphOverlays overlaysForSlReps(List<SlRepResult> reps) => GraphOverlays(
  spans: [
    for (final r in reps)
      GraphOverlaySpan(
        start: r.start,
        end: r.end,
        color: const Color(0x1A000000),
      ),
  ],
  plateEllipses: [
    for (final r in reps)
      if (r.ellipse case final e?)
        PlateEllipseOverlay(
          cx: e.cx,
          cy: e.cy,
          semiA: e.semiA,
          semiB: e.semiB,
          angleRad: e.angleRad,
          color: const Color(0xFF9C27B0),
        ),
  ],
);
