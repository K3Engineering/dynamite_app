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

/// Window shading for one rep whose bounds are the whole rep (timed-capture
/// and free-pass molds).
GraphOverlays windowShadeOverlay(RepEvaluation rep) => GraphOverlays(
  spans: [
    GraphOverlaySpan(start: rep.start, end: rep.end, color: kWindowShadeColor),
  ],
);

/// Window shading for every rep whose bounds are the whole rep.
GraphOverlays windowShadeOverlays(List<RepEvaluation> reps) => GraphOverlays(
  spans: [
    for (final r in reps)
      GraphOverlaySpan(start: r.start, end: r.end, color: kWindowShadeColor),
  ],
);

/// Phase shading for one rep's labeled spans, straight from the segmentation
/// (no re-evaluation needed).
GraphOverlays jumpPhaseOverlays(List<PhaseSpan> spans) => GraphOverlays(
  spans: [
    for (final s in spans)
      GraphOverlaySpan(
        start: s.start,
        end: s.end,
        color: cmjPhaseColor(s.label),
      ),
  ],
);

/// Combine per-rep overlays into one annotation set for the graph.
GraphOverlays mergeOverlays(Iterable<GraphOverlays> overlays) => GraphOverlays(
  spans: [for (final o in overlays) ...o.spans],
  markers: [for (final o in overlays) ...o.markers],
  plateEllipses: [for (final o in overlays) ...o.plateEllipses],
  plateTrails: [for (final o in overlays) ...o.plateTrails],
);
