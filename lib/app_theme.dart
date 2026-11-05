import 'package:material_ui/material_ui.dart';

import 'status_colors.dart';

abstract final class AppTheme {
  static final ThemeData light = _buildTheme(
    scaffoldBackgroundColor: const Color(0xFFF8F9FA),
    status: StatusColors.light,
    // ColorScheme.light()/.dark() fall undeclared M3 roles back to base roles,
    // theming some widgets wrong; declare every role the app reads.
    colors: const ColorScheme.light(
      primary: Color(0xFF455A64),
      onPrimary: Colors.white,
      // Explicit device-state surfaces use [StatusColors.stateContainer].
      primaryContainer: Color(0xFF455A64),
      onPrimaryContainer: Colors.white,
      // active tab on the bottom
      secondary: Color(0xFF455A64),
      // icon color of selected tab
      onSecondary: Colors.white,
      // Kept primary-family for M3 widgets themed off this role. A distinct
      // secondaryContainer would make determinate progress tracks match their
      // fill.
      secondaryContainer: Color(0xFF455A64),
      onSecondaryContainer: Colors.white,
      tertiary: Color.fromARGB(255, 211, 47, 47),
      onTertiary: Colors.white,
      surface: Colors.white,
      // text
      onSurface: Colors.black,
      error: Color(0xFFB00020),
      onError: Colors.white,
      errorContainer: Color(0xFFB00020),
      onErrorContainer: Colors.white,
      // Dimmed/inactive content (BT-off icon, expired-scan rows).
      outline: Color(0xFF78909C), // blueGrey 400
      // Quiet hairlines; Dividers default to this role in M3.
      outlineVariant: Color(0xFFCFD8DC), // blueGrey 100
      // De-emphasized secondary text (settings notes, plot axis labels).
      onSurfaceVariant: Color(0xFF546E7A), // blueGrey 600
      // De-emphasized surface (the stale device row's card tint):
      // onSurface at 6% blended over surface.
      surfaceContainerHighest: Color(0xFFF0F0F0),
      // SnackBar themes itself off inverseSurface/onInverseSurface; identical
      // in both schemes, so one toast style regardless of mode. Error toasts
      // override background/content via showErrorSnackBar. inversePrimary is
      // the snackbar action-label accent.
      inverseSurface: Color(0xFF323232),
      onInverseSurface: Colors.white,
      inversePrimary: Color(0xFF89B2C5),
    ),
  );

  static final ThemeData dark = _buildTheme(
    scaffoldBackgroundColor: const Color(0xFF121212),
    status: StatusColors.dark,
    colors: const ColorScheme.dark(
      primary: Color.fromARGB(255, 103, 155, 179),
      onPrimary: Colors.white,
      // White on this container is mediocre contrast; kept for the existing
      // dark look.
      primaryContainer: Color.fromARGB(255, 103, 155, 179),
      onPrimaryContainer: Colors.white,
      secondary: Color.fromARGB(255, 137, 178, 197),
      onSecondary: Colors.black,
      // Same declaration as light (= secondary); see the comment there.
      secondaryContainer: Color.fromARGB(255, 137, 178, 197),
      onSecondaryContainer: Colors.black,
      tertiary: Color(0xFFEF5350),
      onTertiary: Colors.white,
      surface: Color(0xFF1E1E1E),
      onSurface: Colors.white,
      error: Color(0xFFCF6679),
      onError: Colors.black,
      errorContainer: Color(0xFFCF6679),
      onErrorContainer: Colors.black,
      // Dimmed/inactive content (BT-off icon, expired-scan rows).
      outline: Color(0xFF90A4AE), // blueGrey 300
      outlineVariant: Color(0xFF546E7A), // blueGrey 600
      onSurfaceVariant: Color(0xFF78909C), // blueGrey 400
      // De-emphasized surface (the stale device row's card tint):
      // onSurface at 6% blended over surface.
      surfaceContainerHighest: Color(0xFF2B2B2B),
      // Same toast/notice surfaces as light; see the light scheme.
      inverseSurface: Color(0xFF323232),
      onInverseSurface: Colors.white,
      inversePrimary: Color(0xFF89B2C5),
    ),
  );
}

ThemeData _buildTheme({
  required Color scaffoldBackgroundColor,
  required StatusColors status,
  required ColorScheme colors,
}) => ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: scaffoldBackgroundColor,
  extensions: [status],
  colorScheme: colors,
  navigationBarTheme: _navBarTheme(colors),
);

// M3's inactive nav color is too quiet; only that moves, to onSurface.
// Sizes replicate the M3 defaults (this property replaces the whole resolve).
NavigationBarThemeData _navBarTheme(ColorScheme colors) {
  const inactiveAlpha = 0.8;
  return NavigationBarThemeData(
    iconTheme: WidgetStateProperty.resolveWith(
      (states) => IconThemeData(
        size: 24,
        color: states.contains(WidgetState.disabled)
            ? colors.onSurfaceVariant.withValues(alpha: 0.38)
            : states.contains(WidgetState.selected)
            ? colors.onSecondaryContainer
            : colors.onSurface.withValues(alpha: inactiveAlpha),
      ),
    ),
    labelTextStyle: WidgetStateProperty.resolveWith(
      (states) => TextStyle(
        fontSize: 12,
        fontWeight: .w500,
        letterSpacing: 0.5,
        color: states.contains(WidgetState.disabled)
            ? colors.onSurfaceVariant.withValues(alpha: 0.38)
            : states.contains(WidgetState.selected)
            ? colors.onSurface
            : colors.onSurface.withValues(alpha: inactiveAlpha),
      ),
    ),
  );
}
