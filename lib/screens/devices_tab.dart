import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ble_link_manager.dart';
import '../widgets/bt_icon.dart';

class DevicesTab extends StatefulWidget {
  final bool isActive;

  const DevicesTab({super.key, this.isActive = false});

  @override
  State<DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<DevicesTab> {
  @override
  void initState() {
    super.initState();
    if (widget.isActive) {
      _requestBluetoothIfActive();
    }
  }

  @override
  void didUpdateWidget(covariant DevicesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _requestBluetoothIfActive();
    }
  }

  void _requestBluetoothIfActive() {
    // Post-frame callback ensures we don't try to access providers before
    // the widget tree is fully initialized during the first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // ignore: discarded_futures
        context.read<BleLinkManager>().requestEnableBluetooth();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bt = context.watch<BleLinkManager>();
    // Usable connection (services discovered + ADC feed streaming). "Connected"
    // in the UI means this — not merely that a GATT link exists.
    final isStreaming = bt.isStreaming;
    // GATT link is up but post-connect setup is still running ("Setting up…").
    final isSettingUp = bt.isSettingUp;
    // The link is up (setting up OR streaming) — the connected card is shown for
    // both so the user can see progress and cancel a stuck setup.
    final isLinkUp = bt.selectedDeviceId.isNotEmpty;
    // A link is "busy" whenever it is mid-transition, active, or cooling down
    // after a disconnect; device-row Connect buttons stay disabled until the
    // link returns to idle. This is what prevents the disconnect→reconnect
    // double-click race — including the web post-disconnect settle window where
    // the stack isn't yet ready to accept a fresh connection.
    final isBusy =
        isLinkUp || bt.isConnecting || bt.isDisconnecting || bt.isCoolingDown;
    // The specific device currently in its post-disconnect cooldown window (web
    // only); its row shows "Please wait…" instead of "Connect".
    final coolingDownDeviceId = bt.isCoolingDown ? bt.link.deviceId : '';

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
                        isSettingUp: isSettingUp,
                        isConnected: isStreaming,
                        isDisconnecting: bt.isDisconnecting,
                        isCoolingDown: bt.isCoolingDown,
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

          // Connected section — shown while the link is up (setting up OR
          // streaming) so the user can watch setup progress and cancel a stuck
          // one. The header/icon distinguish "Setting up…" from "Connected".
          if (isLinkUp) ...[
            Text(
              isStreaming ? 'Connected' : 'Setting up…',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: Icon(
                  isStreaming
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_searching,
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

          // Always-visible Demo Device Card pinned at the bottom
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: ListTile(
              leading: const Icon(Icons.science, color: Colors.teal),
              title: const Text('Demo Device'),
              subtitle: const Text('Simulated data — no hardware'),
              trailing: FilledButton(
                onPressed: isBusy
                    ? null
                    : () async {
                        try {
                          await bt.connectToDemoDevice();
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Failed to connect to Demo Device.',
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
          const SizedBox(height: 16),

          if (!isLinkUp && bt.devices.isEmpty && !bt.isScanning)
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
                  child: Text(
                    device.deviceId == coolingDownDeviceId
                        ? 'Please wait…'
                        : 'Connect',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
