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
BtStatusVisual btStatusVisual({
  required BtLinkState linkState,
  required AvailabilityState availability,
  required bool isScanning,
  required bool hasDevices,
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
        // Web: the link has torn down but the stack isn't ready to reconnect
        // yet. Connect stays disabled through this settle window.
        return (Icons.bluetooth_searching, active, 'Almost ready…');
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
        // stops, so surface that rather than implying a scan is required.
        if (hasDevices) {
          return (Icons.bluetooth, connected, 'Tap a device to connect');
        }
        // NOTE: availability is not reliably signalled on all platforms
        // (e.g. web, or Bluetooth already off at launch), so we avoid
        // claiming "ready" and just state the action the user can take.
        return (Icons.bluetooth, connected, 'Tap Scan to find devices');
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
      // ignore: unreachable_switch_default
      default:
        return (Icons.question_mark, colors.outline, 'Bluetooth unavailable');
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
/// anything is in flight). Driven directly by the per-device link state plus
/// the global adapter availability and scan flag — no derived flags to keep
/// in sync at the call site.
class BluetoothIndicator extends StatelessWidget {
  /// State of the single active device link.
  final BtLinkState linkState;

  /// Radio/adapter availability.
  final AvailabilityState state;

  final bool isScanning;

  /// Any discovered devices in the list (for the idle hint).
  final bool hasDevices;

  const BluetoothIndicator({
    super.key,
    required this.linkState,
    required this.state,
    this.isScanning = false,
    this.hasDevices = false,
  });

  @override
  Widget build(BuildContext context) {
    final visual = btStatusVisual(
      linkState: linkState,
      availability: state,
      isScanning: isScanning,
      hasDevices: hasDevices,
      status: Theme.of(context).extension<StatusColors>()!,
      colors: Theme.of(context).colorScheme,
    );

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
    );
  }
}
