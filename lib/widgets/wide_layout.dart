import 'dart:math' as math;

/// Width at or above which the shell replaces the bottom navigation bar with
/// a side navigation rail.
const double kWideLayoutWidth = 1024;

/// Content cap applied by [contentSideInset].
const double kContentMaxWidth = 800;

/// Horizontal inset that caps list content at [kContentMaxWidth] while the
/// scrollable itself stays full-width (so the scrollbar lives on the page
/// edge and wheel events scroll from anywhere). Pass the scrollable's own
/// constraint width — e.g. from a `LayoutBuilder`, since `MediaQuery`
/// includes the navigation rail.
double contentSideInset(double viewportWidth) =>
    math.max(16, (viewportWidth - kContentMaxWidth) / 2);
