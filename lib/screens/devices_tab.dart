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
  BluetoothHandling? _bt;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Register transient-notice callbacks once. Using read (not watch) so we
    // don't rebuild on them; the callbacks show transient SnackBars.
    final bt = context.read<BluetoothHandling>();
    if (!identical(_bt, bt)) {
      _bt?.onDisconnectTimeout = null;
      _bt?.onConnectionFailed = null;
      _bt = bt;
      bt.onDisconnectTimeout = _showDisconnectTimeoutNotice;
      bt.onConnectionFailed = _showConnectionFailedNotice;
    }
  }

  @override
  void dispose() {
    if (_bt?.onDisconnectTimeout == _showDisconnectTimeoutNotice) {
      _bt?.onDisconnectTimeout = null;
    }
    if (_bt?.onConnectionFailed == _showConnectionFailedNotice) {
      _bt?.onConnectionFailed = null;
    }
    super.dispose();
  }

  void _showDisconnectTimeoutNotice(String deviceName) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$deviceName didn\'t disconnect cleanly.')),
    );
  }

  void _showConnectionFailedNotice(String deviceName) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Lost connection to $deviceName during setup.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bt = context.watch<BluetoothHandling>();
    final isConnected = bt.selectedDeviceId.isNotEmpty;
    // A link is "busy" whenever it is mid-transition or active; device-row
    // Connect buttons stay disabled until the link returns to idle. This is
    // what prevents the disconnect→reconnect double-click race.
    final isBusy = isConnected || bt.isConnecting || bt.isDisconnecting;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Text('Devices', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(width: 12),
              // Right cluster: status text + icon + Scan button, flush right.
              // Expanded gives the cluster the remaining width; the cluster's
              // own Row right-aligns its content within it.
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: BluetoothIndicator(
                        isScanning: bt.isScanning,
                        isConnecting: bt.isConnecting,
                        isConnected: isConnected,
                        isDisconnecting: bt.isDisconnecting,
                        hasDevices: bt.devices.isNotEmpty,
                        state: bt.bluetoothState,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () async {
                        await bt.toggleScan();
                      },
                      child: Text(bt.isScanning ? 'Stop' : 'Scan'),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
                subtitle: Text(
                  bt.connectedRssi != null
                      ? 'ID: ${bt.selectedDeviceId}  •  RSSI: ${bt.connectedRssi} dBm'
                      : 'ID: ${bt.selectedDeviceId}',
                ),
                trailing: TextButton(
                  // Disabled while the disconnect is in flight so the button
                  // truthfully reflects the in-progress teardown.
                  onPressed: bt.isDisconnecting
                      ? null
                      : () async {
                          await bt.disconnectSelectedDevice();
                        },
                  child: Text(
                    bt.isDisconnecting ? 'Disconnecting…' : 'Disconnect',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          if (!isConnected && bt.devices.isEmpty && !bt.isScanning)
            Padding(
              padding: const EdgeInsets.only(top: 64),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.bluetooth_searching,
                      size: 64,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No devices found',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tap Scan at the top to search for nearby devices',
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                  ],
                ),
              ),
            ),

          if (bt.devices.isNotEmpty || bt.isScanning) ...[
            Text(
              'Available Devices',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
            const SizedBox(height: 8),
          ],

          for (final device in bt.devices)
            Card(
              child: ListTile(
                leading: const Icon(Icons.bluetooth, color: Colors.blueGrey),
                title: Text(device.name ?? 'Unknown device'),
                subtitle: Text(
                  device.rssi != null ? 'RSSI: ${device.rssi} dBm' : 'RSSI: --',
                ),
                trailing: FilledButton(
                  // Disabled whenever a link is busy (connecting/connected/
                  // disconnecting) so we never issue a connect against a link
                  // that is still tearing down — this is the fix for needing a
                  // second Connect click right after Disconnect.
                  onPressed: isBusy
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
