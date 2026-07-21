import 'package:flutter/material.dart';

/// Semantic Bluetooth link-status colors, resolved per theme brightness.
///
/// [ColorScheme] has no "in-progress" / "connected" roles, which is why raw
/// `Colors.lightBlue` / `Colors.blueAccent` used to be sprinkled through the
/// BLE widgets. Registered on both app themes in `main.dart`; read via
/// `Theme.of(context).extension<StatusColors>()!`.
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({required this.linkActive, required this.linkConnected});

  /// A link transition is in flight: scanning, connecting, post-connect
  /// setup, disconnecting, or the post-disconnect cooldown.
  final Color linkActive;

  /// The link is up and usable (streaming).
  final Color linkConnected;

  static const StatusColors light = StatusColors(
    linkActive: Colors.lightBlue,
    linkConnected: Colors.blueAccent,
  );

  static const StatusColors dark = StatusColors(
    linkActive: Color(0xFF81D4FA), // lightBlue 300
    linkConnected: Color(0xFF82B1FF), // blueAccent 100
  );

  @override
  StatusColors copyWith({Color? linkActive, Color? linkConnected}) =>
      StatusColors(
        linkActive: linkActive ?? this.linkActive,
        linkConnected: linkConnected ?? this.linkConnected,
      );

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      linkActive: Color.lerp(linkActive, other.linkActive, t)!,
      linkConnected: Color.lerp(linkConnected, other.linkConnected, t)!,
    );
  }
}
