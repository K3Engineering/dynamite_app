import 'package:material_ui/material_ui.dart';

import '../analysis/metrics_sway.dart';
import '../models/graph_overlays.dart';

/// A sway metric × window table. One window shows bare values; a two-window
/// test (Romberg) gets a ratio column instead of a meaningless cross-
/// condition mean.
class SwayMetricsTable extends StatelessWidget {
  const SwayMetricsTable({super.key, required this.reps});

  final List<SwayRepResult> reps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.bold,
    );
    final ratio = reps.length == 2;
    return Table(
      columnWidths: {
        0: const FlexColumnWidth(2.2),
        for (int i = 1; i <= reps.length; i++) i: const FlexColumnWidth(),
        if (ratio) reps.length + 1: const FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            const SizedBox.shrink(),
            for (final r in reps)
              Text(
                r.label.isEmpty ? 'Rep ${r.number}' : r.label,
                style: headerStyle,
                textAlign: TextAlign.end,
              ),
            if (ratio)
              Text(
                _ratioHeader(),
                style: headerStyle,
                textAlign: TextAlign.end,
              ),
          ],
        ),
        for (final def in swayMetrics)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(def.label, style: theme.textTheme.bodySmall),
              ),
              for (final r in reps) _cell(context, def, r.metric(def.id)),
              if (ratio) _cell(context, def, _ratioOf(def.id)),
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

  Widget _cell(BuildContext context, SwayMetricDef def, double? value) =>
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
