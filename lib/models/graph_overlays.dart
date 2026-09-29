import 'package:material_ui/material_ui.dart';

/// Semi-transparent shading over a sample-index range, drawn behind the trace.
@immutable
class GraphOverlaySpan {
  const GraphOverlaySpan({
    required this.start,
    required this.end,
    required this.color,
  });

  /// Absolute sample indices; `[start, end)`.
  final int start;
  final int end;
  final Color color;
}

/// A full-height vertical rule at one sample index.
@immutable
class GraphOverlayMarker {
  const GraphOverlayMarker({required this.index, required this.color});

  final int index;
  final Color color;
}

/// Annotation chrome layered on a time-series graph (rep phases, boundaries).
@immutable
class GraphOverlays {
  const GraphOverlays({this.spans = const [], this.markers = const []});

  final List<GraphOverlaySpan> spans;
  final List<GraphOverlayMarker> markers;
}

/// Fill color for a CMJ phase label (see [CmjPhases.spans]).
Color cmjPhaseColor(String label) => switch (label) {
  'eccentric' => const Color(0x332196F3), // blue
  'concentric' => const Color(0x334CAF50), // green
  'flight' => const Color(0x33FFC107), // amber
  'landing' => const Color(0x33F44336), // red
  _ => const Color(0x22000000),
};
