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

/// A polyline of CoP positions on the 2D plate pane (a gait line through
/// one footstrike), in support-normalized plate units (±1 = a plate edge).
@immutable
class PlateTrailOverlay {
  const PlateTrailOverlay({required this.points, required this.color});

  final List<(double, double)> points;
  final Color color;
}

/// A confidence ellipse over a CoP cloud, drawn on the 2D plate pane in
/// support-normalized plate units (±1 = a plate edge).
@immutable
class PlateEllipseOverlay {
  const PlateEllipseOverlay({
    required this.cx,
    required this.cy,
    required this.semiA,
    required this.semiB,
    required this.angleRad,
    required this.color,
  });

  /// Center of the cloud (mean CoP).
  final double cx;
  final double cy;

  /// Semi-axis lengths, major then minor.
  final double semiA;
  final double semiB;

  /// Orientation of the major axis in plate coordinates (+y up).
  final double angleRad;
  final Color color;
}

/// Annotation chrome layered on the graphs: spans/markers for time-series
/// traces, ellipses/trails for the 2D plate pane. Each pane picks what it
/// can draw.
@immutable
class GraphOverlays {
  const GraphOverlays({
    this.spans = const [],
    this.markers = const [],
    this.plateEllipses = const [],
    this.plateTrails = const [],
  });

  final List<GraphOverlaySpan> spans;
  final List<GraphOverlayMarker> markers;
  final List<PlateEllipseOverlay> plateEllipses;
  final List<PlateTrailOverlay> plateTrails;
}

/// Gait-line color by 1-based pass number (cycles through a small palette).
Color gaitTrailColor(int number) => switch (number % 4) {
  1 => const Color(0xFF2196F3), // blue
  2 => const Color(0xFFE91E63), // pink
  3 => const Color(0xFF4CAF50), // green
  _ => const Color(0xFFFF9800), // orange
};

/// Fill color for a CMJ phase label (see [CmjPhases.spans]).
Color cmjPhaseColor(String label) => switch (label) {
  'eccentric' => const Color(0x332196F3), // blue
  'concentric' => const Color(0x334CAF50), // green
  'flight' => const Color(0x33FFC107), // amber
  'landing' => const Color(0x33F44336), // red
  _ => const Color(0x22000000),
};
