import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

import '../services/ble_link_manager.dart' show BtLinkState;

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
    (IconData, Color, String) indicator() {
      // Link states first: any active link or transition outranks scan and
      // adapter status.
      switch (linkState) {
        case BtLinkState.disconnecting:
          return const (
            Icons.bluetooth_searching,
            Colors.lightBlue,
            'Disconnecting…',
          );
        case BtLinkState.cooldown:
          // Web: the link has torn down but the stack isn't ready to reconnect
          // yet. Connect stays disabled through this settle window.
          return const (
            Icons.bluetooth_searching,
            Colors.lightBlue,
            'Almost ready…',
          );
        case BtLinkState.streaming:
          return const (
            Icons.bluetooth_connected,
            Colors.blueAccent,
            'Connected',
          );
        case BtLinkState.connected:
          // GATT link is up but service discovery / ADC subscription is still
          // in progress. Not usable yet.
          return const (
            Icons.bluetooth_searching,
            Colors.lightBlue,
            'Setting up…',
          );
        case BtLinkState.connecting:
          return const (
            Icons.bluetooth_searching,
            Colors.lightBlue,
            'Connecting…',
          );
        case BtLinkState.idle:
          break; // Fall through to scan / adapter status.
      }
      if (isScanning) {
        // On web the device list lives in the browser's own picker popup, not
        // in our list, so we tell the user to choose there.
        return (
          Icons.bluetooth_searching,
          Colors.lightBlue,
          kIsWeb ? 'Choose a device…' : 'Scanning for devices…',
        );
      }
      switch (state) {
        case AvailabilityState.poweredOn:
          // A previously-discovered device can remain connectable after a scan
          // stops, so surface that rather than implying a scan is required.
          if (hasDevices) {
            return const (
              Icons.bluetooth,
              Colors.blueAccent,
              'Tap a device to connect',
            );
          }
          // NOTE: availability is not reliably signalled on all platforms
          // (e.g. web, or Bluetooth already off at launch), so we avoid
          // claiming "ready" and just state the action the user can take.
          return const (
            Icons.bluetooth,
            Colors.blueAccent,
            'Tap Scan to find devices',
          );
        case AvailabilityState.poweredOff:
          return const (
            Icons.bluetooth_disabled,
            Colors.blueGrey,
            'Bluetooth is off',
          );
        case AvailabilityState.unknown:
          return const (
            Icons.question_mark,
            Colors.yellow,
            'Starting up Bluetooth…',
          );
        case AvailabilityState.resetting:
          return const (
            Icons.question_mark,
            Colors.green,
            'Bluetooth resetting…',
          );
        case AvailabilityState.unsupported:
          return const (Icons.stop, Colors.red, 'Bluetooth not supported');
        case AvailabilityState.unauthorized:
          return const (
            Icons.stop,
            Colors.orange,
            'Bluetooth permission needed',
          );
        // ignore: unreachable_switch_default
        default:
          return const (
            Icons.question_mark,
            Colors.grey,
            'Bluetooth unavailable',
          );
      }
    }

    final (IconData icon, Color color, String label) = indicator();
    const double size = 32;
    // Spinner while anything is in flight (scanning or a link transition);
    // the steady "streaming" state gets the plain connected icon.
    final bool showSpinner =
        isScanning ||
        (linkState != BtLinkState.idle && linkState != BtLinkState.streaming);

    final iconStack = Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Icon(icon, size: size, color: color),
        if (showSpinner)
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
        Flexible(
          child: Text(
            label,
            textAlign: TextAlign.right,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
          ),
        ),
        const SizedBox(width: 8),
        iconStack,
      ],
    );
  }
}
