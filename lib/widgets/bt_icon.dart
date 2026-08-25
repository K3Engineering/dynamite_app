import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import '../models/bt_scan.dart' show BtAvailability, BtLinkState;
import 'status_colors.dart';

/// Everything the [BluetoothIndicator] displays, resolved from link/adapter/
/// scan state by [btStatusVisual]; colors are supplied from the theme.
typedef BtStatusVisual = ({
  IconData icon,
  Color color,
  String label,
  bool showSpinner,
});

/// Stage label for a non-idle link state ("Connecting…", "Disconnecting…");
/// null for [BtLinkState.idle], which has no link-side label (the scan /
/// adapter status is the voice there). What each stage means is documented
/// on [BtLinkState] itself. Shared by [btStatusVisual] (Devices tab) and the
/// Live tab's status bar, so the two can't phrase the same state differently.
String? btLinkStateLabel(BtLinkState state) => switch (state) {
  BtLinkState.disconnecting => 'Disconnecting…',
  BtLinkState.streaming => 'Connected',
  BtLinkState.connected => 'Setting up…',
  BtLinkState.readingConstants => 'Reading board constants…',
  BtLinkState.subscribing => 'Starting data stream…',
  BtLinkState.connecting => 'Connecting…',
  BtLinkState.idle => null,
};

/// Map the link/adapter/scan state to the indicator visual. Link states
/// outrank scan status, which outranks adapter status. [status]/[colors]
/// carry the theme's semantic + scheme colors.
///
/// [hasConnectableDevices] is the caller-resolved truth condition for the
/// "Tap a device to connect" hint: devices are discovered AND no link is
/// busy. A busy link — including the demo device, which occupies the single
/// link slot and so gets BLE connects refused — disables every Connect
/// button on screen, so the hint must not be emitted then.
///
/// Two callers, two scopes: the Devices tab's top indicator passes
/// [BtLinkState.idle] so it speaks only for the adapter and the scan (link
/// state belongs to the per-device rows); the active device row passes the
/// real link state and uses the link branches.
BtStatusVisual btStatusVisual({
  required BtLinkState linkState,
  required BtAvailability availability,
  required bool isScanning,
  required bool hasConnectableDevices,
  required StatusColors status,
  required ColorScheme colors,
}) {
  final active = status.linkActive;
  final connected = status.linkConnected;

  (IconData, Color, String) resolve() {
    // Any link transition outranks scan / adapter status. Every non-idle
    // state shares the searching-in-flight treatment except the steady
    // streaming state (see [showSpinner] below).
    if (linkState != BtLinkState.idle) {
      final streaming = linkState == BtLinkState.streaming;
      return (
        streaming ? Icons.bluetooth_connected : Icons.bluetooth_searching,
        streaming ? connected : active,
        btLinkStateLabel(linkState)!,
      );
    }
    if (isScanning) {
      // On web the device list lives in the browser's own picker popup, not
      // in our list, so we tell the user to choose there.
      return (
        Icons.bluetooth_searching,
        active,
        kIsWeb ? 'Choose a device…' : 'Scanning for devices…',
      );
    }
    switch (availability) {
      case BtAvailability.poweredOn:
        // A previously-discovered device can remain connectable after a scan
        // stops, so surface that rather than implying a scan is required —
        // but only while a Connect action actually exists (see
        // [hasConnectableDevices]): while a link is busy every Connect
        // button is disabled and the active device row is the voice.
        if (hasConnectableDevices) {
          return (Icons.bluetooth, connected, 'Tap a device to connect');
        }
        // Otherwise an empty label: with nothing found, the Devices tab's
        // empty block is the single voice for "no devices, tap Scan"
        // guidance; with a link busy, the active row speaks. Repeating
        // either here would put the same instruction twice on screen.
        // The indicator renders icon-only for an empty label.
        return (Icons.bluetooth, connected, '');
      case BtAvailability.poweredOff:
        return (Icons.bluetooth_disabled, colors.outline, 'Bluetooth is off');
      case BtAvailability.unknown:
        return (Icons.question_mark, colors.outline, 'Starting up Bluetooth…');
      case BtAvailability.resetting:
        return (Icons.question_mark, active, 'Bluetooth resetting…');
      case BtAvailability.unsupported:
        return (Icons.stop, colors.error, 'Bluetooth not supported');
      case BtAvailability.unauthorized:
        return (Icons.stop, colors.tertiary, 'Bluetooth permission needed');
    }
  }

  final (icon, color, label) = resolve();
  return (
    icon: icon,
    color: color,
    label: label,
    // Spinner while anything is in flight (scanning or a link transition);
    // the steady "streaming" state gets the plain connected icon.
    showSpinner:
        isScanning ||
        (linkState != BtLinkState.idle && linkState != BtLinkState.streaming),
  );
}

/// The Devices tab top indicator's presentation mode, resolved by
/// [topIndicatorMode]. "Quiet when nominal": the indicator draws an icon
/// only when the glyph carries real information — scan progress or an
/// adapter failure (those glyphs are distinct from the device rows' BLE
/// icons, so nothing reads as a duplicate) — and stays text-only or fully
/// silent in powered-on nominal states, where a static Bluetooth glyph
/// would read as a stale link-state icon next to the rows' stateful ones.
enum TopIndicatorMode {
  /// Nothing renders: the tab's empty block is on screen and is the single
  /// voice for the state (icon included).
  quiet,

  /// Label only, no icon: powered-on nominal states ("Tap a device to
  /// connect"). An empty label renders nothing at all (e.g. a link is
  /// busy — the active device row is the voice then).
  textOnly,

  /// Icon (with spinner while in flight) plus label: scanning, or an
  /// adapter failure the empty block isn't covering.
  iconAndLabel,
}

/// Resolve the top indicator's presentation mode from adapter/scan state
/// and whether the tab's empty block is on screen. The empty block is the
/// single voice for empty states, so whenever it shows the indicator goes
/// fully quiet — its icon and label would duplicate the block's a hundred
/// pixels above it. Adapter failures normally imply an empty device list
/// (no scan is possible, and poweredOff clears the list), so their
/// icon + label only survive the dedupe in the rare case of a stale
/// populated list (e.g. permission revoked mid-session).
TopIndicatorMode topIndicatorMode({
  required BtAvailability availability,
  required bool isScanning,
  required bool emptyBlockVisible,
}) {
  // The empty block speaks (icon included); it can only show while not
  // scanning, so this can't suppress the scan progress below.
  if (emptyBlockVisible) return TopIndicatorMode.quiet;
  // Scanning: progress is real information — spinner + label.
  if (isScanning) return TopIndicatorMode.iconAndLabel;
  // Adapter failures: distinct glyphs (off / permission / unsupported /
  // startup) carry real information.
  if (availability != BtAvailability.poweredOn) {
    return TopIndicatorMode.iconAndLabel;
  }
  // Powered-on nominal: no icon.
  return TopIndicatorMode.textOnly;
}

/// Compact Bluetooth status readout for the Devices tab's status row.
class BluetoothIndicator extends StatelessWidget {
  final BtStatusVisual visual;

  /// How much of [visual] to draw (see [topIndicatorMode]).
  final TopIndicatorMode mode;

  const BluetoothIndicator({
    super.key,
    required this.visual,
    required this.mode,
  });

  @override
  Widget build(BuildContext context) {
    if (mode == TopIndicatorMode.quiet) {
      return const SizedBox.shrink();
    }
    const double size = 32;
    final label = visual.label;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mode == TopIndicatorMode.iconAndLabel) ...[
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(visual.icon, size: size, color: visual.color),
              if (visual.showSpinner)
                const SizedBox(
                  height: size,
                  width: size,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (label.isNotEmpty) const SizedBox(width: 8),
        ],
        if (label.isNotEmpty)
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
