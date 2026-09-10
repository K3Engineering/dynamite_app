import 'package:material_ui/material_ui.dart';

/// Semantic status colors that [ColorScheme] doesn't provide.
///
/// Registered on both app themes in `main.dart`; read via
/// `Theme.of(context).extension<StatusColors>()!`.
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.linkActive,
    required this.linkConnected,
    required this.linkFault,
    required this.onConnectedWarning,
  });

  /// A link transition is in flight: scanning, connecting, post-connect
  /// setup, disconnecting, or a device inside its reconnect-settle window.
  final Color linkActive;

  /// The link is up and usable (streaming).
  final Color linkConnected;

  /// The link is up but faulted: the connect-time flash read failed a strict
  /// parse, so the device is unusable.
  final Color linkFault;

  /// Warning content on a [ColorScheme.primaryContainer] surface (the
  /// connected device row and the live status bar).
  final Color onConnectedWarning;

  static const StatusColors light = StatusColors(
    linkActive: Colors.lightBlue,
    linkConnected: Colors.blueAccent,
    linkFault: Color(0xFFC62828), // red 800
    onConnectedWarning: Color(0xFFFF8A80), // redAccent 100
  );

  static const StatusColors dark = StatusColors(
    linkActive: Color(0xFF81D4FA), // lightBlue 300
    linkConnected: Color(0xFF82B1FF), // blueAccent 100
    linkFault: Color(0xFFEF5350), // red 400
    onConnectedWarning: Color(0xFFEF5350), // red 400
  );

  @override
  StatusColors copyWith({
    Color? linkActive,
    Color? linkConnected,
    Color? linkFault,
    Color? onConnectedWarning,
  }) => StatusColors(
    linkActive: linkActive ?? this.linkActive,
    linkConnected: linkConnected ?? this.linkConnected,
    linkFault: linkFault ?? this.linkFault,
    onConnectedWarning: onConnectedWarning ?? this.onConnectedWarning,
  );

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      linkActive: Color.lerp(linkActive, other.linkActive, t)!,
      linkConnected: Color.lerp(linkConnected, other.linkConnected, t)!,
      linkFault: Color.lerp(linkFault, other.linkFault, t)!,
      onConnectedWarning: Color.lerp(
        onConnectedWarning,
        other.onConnectedWarning,
        t,
      )!,
    );
  }
}
