import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ble_link_manager.dart';
import '../widgets/bt_icon.dart';
import '../widgets/empty_placeholder.dart';
import '../widgets/section_header.dart';
import '../widgets/status_colors.dart';

class DevicesTab extends StatelessWidget {
  const DevicesTab({super.key});

  /// Run a connect attempt, surfacing a failure as a snackbar naming
  /// [deviceName] with the underlying error detail (timeout vs GATT error vs
  /// user-cancelled web picker are wildly different diagnoses). Connect
  /// buttons are already disabled while a link is busy, so this only handles
  /// the rejected attempt itself.
  Future<void> _connectWithFeedback(
    BuildContext context,
    Future<void> Function() connect,
    String deviceName,
  ) async {
    try {
      await connect();
    } catch (e) {
      debugPrint('Connect to $deviceName failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect to $deviceName: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bt = context.watch<BleLinkManager>();
    // Usable connection (services discovered + ADC feed streaming). "Connected"
    // in the UI means this — not merely that a GATT link exists.
    final isStreaming = bt.isStreaming;
    // The link is up (setting up OR streaming) — the connected card is shown for
    // both so the user can see progress and cancel a stuck setup.
    final isLinkUp = bt.isLinkUp;
    // A connect attempt is in flight; the card shows "Connecting…" with a
    // Cancel button so a hung attempt (or a changed mind) doesn't have to
    // wait out the connect timeout.
    final isConnecting = bt.link.isConnecting;
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
                        linkState: bt.link.state,
                        state: bt.bluetoothState,
                        isScanning: bt.isScanning,
                        hasDevices: bt.devices.isNotEmpty,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // TODO(ux): see BleLinkManager._startScan — starting a
                    // scan while streaming kills the active link (and any
                    // in-progress recording). Decide disable-vs-confirm.
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

          // Connected section — shown while a link attempt is in flight or the
          // link is up (connecting / setting up / streaming) so the user can
          // watch progress and cancel a stuck one. The header/icon distinguish
          // the three states.
          if (isLinkUp || isConnecting) ...[
            Text(
              isStreaming
                  ? 'Connected'
                  : isConnecting
                  ? 'Connecting…'
                  : 'Setting up…',
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
                  color: isStreaming
                      ? Theme.of(
                          context,
                        ).extension<StatusColors>()!.linkConnected
                      : Theme.of(context).extension<StatusColors>()!.linkActive,
                ),
                title: Text(bt.connectedDeviceName),
                subtitle: Text(
                  bt.connectedRssi != null
                      ? 'ID: ${bt.link.deviceId}  •  RSSI: ${bt.connectedRssi} dBm'
                      : 'ID: ${bt.link.deviceId}',
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
                    bt.isDisconnecting
                        ? 'Disconnecting…'
                        : isConnecting
                        ? 'Cancel'
                        : 'Disconnect',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // BLE devices section — always shown so the page structure stays
          // predictable; the empty state lives inside it.
          const SectionHeader('BLE devices'),
          const SizedBox(height: 8),

          if (bt.devices.isEmpty && !bt.isScanning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: EmptyPlaceholder(
                icon: Icons.bluetooth_searching,
                title: 'No devices found',
                hint: 'Tap Scan at the top to search for nearby devices',
              ),
            ),

          for (final device in bt.devices)
            Card(
              child: ListTile(
                leading: Icon(
                  Icons.bluetooth,
                  color: Theme.of(context).colorScheme.outline,
                ),
                title: Text(device.name ?? 'Unknown device'),
                subtitle: Text(
                  device.rssi != null ? 'RSSI: ${device.rssi} dBm' : 'RSSI: --',
                ),
                trailing: FilledButton(
                  // Disabled whenever a link is busy (connecting/connected/
                  // disconnecting) so we never issue a connect against a link
                  // that is still tearing down — this is the fix for needing a
                  // second Connect click right after Disconnect.
                  onPressed: bt.linkBusy
                      ? null
                      : () => _connectWithFeedback(
                          context,
                          () => bt.connectToDevice(device.deviceId),
                          device.name ?? 'device',
                        ),
                  child: Text(
                    device.deviceId == coolingDownDeviceId
                        ? 'Please wait…'
                        : 'Connect',
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),

          // Demo devices section — simulated hardware, kept at the bottom so
          // real BLE devices get top billing.
          const SectionHeader('Demo devices'),
          const SizedBox(height: 8),
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: ListTile(
              leading: const Icon(Icons.science, color: Colors.teal),
              title: const Text('Demo Device'),
              subtitle: const Text('Simulated data — no hardware'),
              trailing: FilledButton(
                onPressed: bt.linkBusy
                    ? null
                    : () => _connectWithFeedback(
                        context,
                        bt.connectToDemoDevice,
                        'Demo Device',
                      ),
                child: const Text('Connect'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
