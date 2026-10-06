import 'package:material_ui/material_ui.dart' show Color;

import '../models/graph_overlays.dart';
import 'metric_eval.dart';
import 'test_result.dart';

// ---------------------------------------------------------------------------
// Graph overlay builders shared by the live runner and a re-opened session
// ---------------------------------------------------------------------------

/// Faint shading for a fixed-duration capture window (sway / isometric /
/// single-leg / gait), as opposed to the per-phase jump colors.
const Color kWindowShadeColor = Color(0x1A000000);

/// Window shading for reps whose bounds are the whole rep (timed-capture and
/// free-pass molds).
GraphOverlays windowShadeOverlays(List<RepEvaluation> reps) => GraphOverlays(
  spans: [
    for (final r in reps)
      GraphOverlaySpan(start: r.start, end: r.end, color: kWindowShadeColor),
  ],
);

/// Phase shading for every rep of a jump-family [TestResult], straight from
/// the persisted spans (no re-evaluation needed).
GraphOverlays jumpPhaseOverlays(TestResult result) => GraphOverlays(
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
