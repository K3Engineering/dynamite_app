import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

import '../services/ble_link_manager.dart' show BtLinkState;
import 'status_colors.dart';

/// Everything the [BluetoothIndicator] displays, resolved from link/adapter/
/// scan state by [btStatusVisual] (a pure, context-free function — the
/// mapping is unit-tested; colors are supplied from the theme).
typedef BtStatusVisual = ({
  IconData icon,
  Color color,
  String label,
  bool showSpinner,
});

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
  required AvailabilityState availability,
  required bool isScanning,
  required bool hasConnectableDevices,
  required StatusColors status,
  required ColorScheme colors,
}) {
  final active = status.linkActive;
  final connected = status.linkConnected;

  (IconData, Color, String) resolve() {
    switch (linkState) {
      case BtLinkState.disconnecting:
        return (Icons.bluetooth_searching, active, 'Disconnecting…');
      case BtLinkState.cooldown:
        // Web: a live link just tore down and the stack isn't ready to
        // accept a fresh connection yet. Connect stays disabled through this
        // settle window.
        return (Icons.bluetooth_searching, active, 'Waiting after disconnect…');
      case BtLinkState.streaming:
        return (Icons.bluetooth_connected, connected, 'Connected');
      case BtLinkState.connected:
        // GATT link is up but service discovery / ADC subscription is still
        // in progress. Not usable yet.
        return (Icons.bluetooth_searching, active, 'Setting up…');
      case BtLinkState.connecting:
        return (Icons.bluetooth_searching, active, 'Connecting…');
      case BtLinkState.idle:
        break; // Fall through to scan / adapter status.
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
      case AvailabilityState.poweredOn:
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
      case AvailabilityState.poweredOff:
        return (Icons.bluetooth_disabled, colors.outline, 'Bluetooth is off');
      case AvailabilityState.unknown:
        return (Icons.question_mark, colors.outline, 'Starting up Bluetooth…');
      case AvailabilityState.resetting:
        return (Icons.question_mark, active, 'Bluetooth resetting…');
      case AvailabilityState.unsupported:
        return (Icons.stop, colors.error, 'Bluetooth not supported');
      case AvailabilityState.unauthorized:
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

/// Compact Bluetooth status readout (icon + hint text, with a spinner while
/// anything is in flight). Renders a [BtStatusVisual] precomputed by the
/// caller via [btStatusVisual] — the same visual can feed several surfaces
/// (this indicator, the Devices tab's empty block) without recomputing.
/// An empty label renders icon-only (the quiet "powered on, nothing to
/// report" state) rather than reserving a blank text slot.
class BluetoothIndicator extends StatelessWidget {
  /// The resolved status visual to display.
  final BtStatusVisual visual;

  const BluetoothIndicator({super.key, required this.visual});

  @override
  Widget build(BuildContext context) {
    const double size = 32;
    final iconStack = Stack(
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
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        iconStack,
        if (visual.label.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              visual.label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
