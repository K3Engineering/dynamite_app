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
  late BluetoothHandling _bt;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bt = Provider.of<BluetoothHandling>(context, listen: false);
    _bt.startProcessing(_onBtStateChange);
  }

  @override
  void dispose() {
    _bt.stopProcessing(_onBtStateChange);
    super.dispose();
  }

  void _onBtStateChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _bt.selectedDeviceId.isNotEmpty;

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
                title: Text(_bt.connectedDeviceName),
                subtitle: Text('ID: ${_bt.selectedDeviceId}'),
                trailing: TextButton(
                  onPressed: () async {
                    await _bt.disconnectSelectedDevice();
                    setState(() {});
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
                isScanning: _bt.isScanning,
                state: _bt.bluetoothState,
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () async {
                  await _bt.toggleScan();
                },
                child: Text(_bt.isScanning ? 'Stop scanning' : 'Scan'),
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (_bt.devices.isEmpty && !_bt.isScanning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  'Tap Scan to search for devices',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ),

          for (final device in _bt.devices)
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
                          await _bt.connectToDevice(device.deviceId);
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
