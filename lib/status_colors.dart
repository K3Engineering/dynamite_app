import 'package:material_ui/material_ui.dart';
import 'package:meta/meta.dart';

/// Semantic status colors that [ColorScheme] doesn't provide.
///
/// Registered on both app themes in `main.dart`; read via
/// `Theme.of(context).extension<StatusColors>()!`.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.linkActive,
    required this.linkConnected,
    required this.onConnectedWarning,
    required this.warningContainer,
    required this.onWarningContainer,
  });

  /// A link transition is in flight: scanning, connecting, post-connect
  /// setup, disconnecting, or a device inside its reconnect-settle window.
  final Color linkActive;

  /// The link is up and usable (streaming).
  final Color linkConnected;

  /// Warning content on a [ColorScheme.primaryContainer] surface (the
  /// connected device row and the live status bar).
  final Color onConnectedWarning;

  /// Attention (not alarm) container/content pair: a state the user set that
  /// must not be forgotten — monitoring paused. Distinct from error red,
  /// which recording owns.
  final Color warningContainer;
  final Color onWarningContainer;

  static const StatusColors light = StatusColors(
    linkActive: Colors.lightBlue,
    linkConnected: Colors.blueAccent,
    onConnectedWarning: Color(0xFFFF8A80), // redAccent 100
    warningContainer: Color(0xFFFFB300), // amber 600
    onWarningContainer: Colors.black,
  );

  static const StatusColors dark = StatusColors(
    linkActive: Color(0xFF81D4FA), // lightBlue 300
    linkConnected: Color(0xFF82B1FF), // blueAccent 100
    onConnectedWarning: Color(0xFFEF5350), // red 400
    warningContainer: Color(0xFFFFCA28), // amber 400
    onWarningContainer: Colors.black,
  );

  @useResult
  @override
  StatusColors copyWith({
    Color? linkActive,
    Color? linkConnected,
    Color? onConnectedWarning,
    Color? warningContainer,
    Color? onWarningContainer,
  }) => StatusColors(
    linkActive: linkActive ?? this.linkActive,
    linkConnected: linkConnected ?? this.linkConnected,
    onConnectedWarning: onConnectedWarning ?? this.onConnectedWarning,
    warningContainer: warningContainer ?? this.warningContainer,
    onWarningContainer: onWarningContainer ?? this.onWarningContainer,
  );

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      linkActive: Color.lerp(linkActive, other.linkActive, t)!,
      linkConnected: Color.lerp(linkConnected, other.linkConnected, t)!,
      onConnectedWarning: Color.lerp(
        onConnectedWarning,
        other.onConnectedWarning,
        t,
      )!,
      warningContainer: Color.lerp(
        warningContainer,
        other.warningContainer,
        t,
      )!,
      onWarningContainer: Color.lerp(
        onWarningContainer,
        other.onWarningContainer,
        t,
      )!,
    );
  }
}
