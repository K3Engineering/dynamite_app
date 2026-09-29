import 'package:material_ui/material_ui.dart';

import '../analysis/metrics_sway.dart';
import '../models/graph_overlays.dart';
import 'metric_grid.dart';

/// The sway metric × window table. One window shows bare values; a two-
/// window test (Romberg) gets a ratio column instead of a meaningless
/// cross-condition mean.
class SwayMetricsTable extends StatelessWidget {
  const SwayMetricsTable({super.key, required this.reps});

  final List<SwayRepResult> reps;

  @override
  Widget build(BuildContext context) {
    final ratio = reps.length == 2;
    return MetricGrid(
      columns: [
        for (final r in reps) r.label.isEmpty ? 'Rep ${r.number}' : r.label,
        if (ratio) _ratioHeader(),
      ],
      rows: [
        for (final def in swayMetrics)
          MetricGridRow(
            label: def.label,
            decimals: def.decimals,
            values: [
              for (final r in reps) r.metric(def.id),
              if (ratio) _ratioOf(def.id),
            ],
          ),
      ],
    );
  }

  /// "EC/EO" for the Romberg pair, a neutral fallback otherwise.
  String _ratioHeader() => switch ((reps[0].label, reps[1].label)) {
    ('Eyes open', 'Eyes closed') => 'EC/EO',
    _ => 'B/A',
  };

  double? _ratioOf(String id) {
    final a = reps[0].metric(id);
    final b = reps[1].metric(id);
    if (a == null || b == null || a == 0) return null;
    return b / a;
  }
}

/// Window shading on the force trace plus a CoP ellipse per window for the
/// 2D plate pane.
GraphOverlays overlaysForSwayReps(List<SwayRepResult> reps) => GraphOverlays(
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
          color: const Color(0xFF2196F3),
        ),
  ],
);
