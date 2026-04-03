import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/bt_handling.dart';
import '../widgets/bt_icon.dart';

class DevicesTab extends StatefulWidget {
  const DevicesTab({super.key});

  @override
  State<DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<DevicesTab> {
  @override
  Widget build(BuildContext context) {
    final bt = context.watch<BluetoothHandling>();
    final isConnected = bt.selectedDeviceId.isNotEmpty;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Devices', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),

          // Connected section
          if (isConnected) ...[
            Text(
              'Connected',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.bluetooth_connected,
                  color: Colors.blueAccent,
                ),
                title: Text(bt.connectedDeviceName),
                subtitle: Text('ID: ${bt.selectedDeviceId}'),
                trailing: TextButton(
                  onPressed: () async {
                    await bt.disconnectSelectedDevice();
                  },
                  child: const Text('Disconnect'),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // Available section
          Row(
            children: [
              Text(
                'Available',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
              const Spacer(),
              BluetoothIndicator(
                isScanning: bt.isScanning,
                state: bt.bluetoothState,
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () async {
                  await bt.toggleScan();
                },
                child: Text(bt.isScanning ? 'Stop scanning' : 'Scan'),
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (bt.devices.isEmpty && !bt.isScanning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  'Tap Scan to search for devices',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ),

          for (final device in bt.devices)
            Card(
              child: ListTile(
                leading: const Icon(Icons.bluetooth, color: Colors.blueGrey),
                title: Text(device.name ?? 'Unknown device'),
                subtitle: Text(
                  device.rssi != null ? 'RSSI: ${device.rssi} dBm' : 'RSSI: --',
                ),
                trailing: FilledButton(
                  onPressed: isConnected
                      ? null
                      : () async {
                          try {
                            await bt.connectToDevice(device.deviceId);
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Failed to connect to ${device.name ?? 'device'}.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                  child: const Text('Connect'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
