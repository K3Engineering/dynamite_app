import 'package:flutter/material.dart';

import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

class BluetoothIndicator extends StatelessWidget {
  final bool isScanning;
  final AvailabilityState state;

  const BluetoothIndicator(
      {super.key, required this.isScanning, required this.state});

  @override
  Widget build(BuildContext context) {
    (IconData, Color) indicator() {
      if (isScanning) {
        return const (Icons.bluetooth_searching, Colors.lightBlue);
      }
      switch (state) {
        case AvailabilityState.poweredOn:
          return const (Icons.bluetooth, Colors.blueAccent);
        case AvailabilityState.poweredOff:
          return const (Icons.bluetooth_disabled, Colors.blueGrey);
        case AvailabilityState.unknown:
          return const (Icons.question_mark, Colors.yellow);
        case AvailabilityState.resetting:
          return const (Icons.question_mark, Colors.green);
        case AvailabilityState.unsupported:
          return const (Icons.stop, Colors.red);
        case AvailabilityState.unauthorized:
          return const (Icons.stop, Colors.orange);
        // ignore: unreachable_switch_default
        default:
          return const (Icons.question_mark, Colors.grey);
      }
    }

    final (IconData icon, Color color) = indicator();
    const double size = 48;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Icon(icon, size: size, color: color),
        if (isScanning)
          const SizedBox(
            height: size,
            width: size,
            child: CircularProgressIndicator(),
          ),
      ],
    );
  }
}
