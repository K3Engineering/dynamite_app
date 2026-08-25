import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Width at or above which the shell replaces the bottom navigation bar with
/// a side navigation rail.
const double kWideLayoutWidth = 1024;

/// Content cap applied by [contentSideInset] and [TabContentColumn].
const double kContentMaxWidth = 800;

/// Horizontal inset that caps list content at [kContentMaxWidth] while the
/// scrollable itself stays full-width (so the scrollbar lives on the page
/// edge and wheel events scroll from anywhere). Pass the scrollable's own
/// constraint width — e.g. from a `LayoutBuilder`, since `MediaQuery`
/// includes the navigation rail. Branch-free: `math.max`, not `if`.
double contentSideInset(double viewportWidth) =>
    math.max(16, (viewportWidth - kContentMaxWidth) / 2);

/// Centered, width-capped wrapper for non-scrolling tab content (e.g. a page
/// header outside the scrollable), aligned with scrollable content clamped
/// via [contentSideInset].
class TabContentColumn extends StatelessWidget {
  const TabContentColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
        child: child,
      ),
    );
  }
}
