import 'package:flutter/material.dart';

import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

class BluetoothIndicator extends StatelessWidget {
  final bool isScanning;
  final bool isConnected;
  final bool showLabel;
  final AvailabilityState state;

  const BluetoothIndicator({
    super.key,
    required this.isScanning,
    required this.state,
    this.isConnected = false,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    (IconData, Color, String) indicator() {
      if (isConnected) {
        return const (
          Icons.bluetooth_connected,
          Colors.blueAccent,
          'Connected',
        );
      }
      if (isScanning) {
        return const (
          Icons.bluetooth_searching,
          Colors.lightBlue,
          'Scanning — pick a device, then Connect',
        );
      }
      switch (state) {
        case AvailabilityState.poweredOn:
          return const (Icons.bluetooth, Colors.blueAccent, 'Ready — tap Scan');
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

    final iconStack = Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Icon(icon, size: size, color: color),
        if (isScanning)
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
