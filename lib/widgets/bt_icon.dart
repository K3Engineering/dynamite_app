import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

class BluetoothIndicator extends StatelessWidget {
  final bool isScanning;
  final bool isConnecting;
  final bool isConnected;
  final bool hasDevices;
  final bool showLabel;
  final AvailabilityState state;

  const BluetoothIndicator({
    super.key,
    required this.isScanning,
    required this.state,
    this.isConnecting = false,
    this.isConnected = false,
    this.hasDevices = false,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    (IconData, Color, String) indicator() {
      // Order matters: most definite / in-progress states first.
      if (isConnected) {
        return const (
          Icons.bluetooth_connected,
          Colors.blueAccent,
          'Connected',
        );
      }
      if (isConnecting) {
        return const (
          Icons.bluetooth_searching,
          Colors.lightBlue,
          'Connecting…',
        );
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
    final bool showSpinner = isScanning || isConnecting;

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

    if (!showLabel) {
      return iconStack;
    }

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
