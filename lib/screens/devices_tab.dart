import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ble_link_manager.dart';
import '../widgets/bt_icon.dart';
import '../widgets/section_header.dart';

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

  /// Run a connect attempt, surfacing a failure as a snackbar naming
  /// [deviceName] with the underlying error detail (timeout vs GATT error vs
  /// user-cancelled web picker are wildly different diagnoses). Connect
  /// buttons are already disabled while a link is busy, so this only handles
  /// the rejected attempt itself.
  Future<void> _connectWithFeedback(
    Future<void> Function() connect,
    String deviceName,
  ) async {
    try {
      await connect();
    } catch (e) {
      debugPrint('Connect to $deviceName failed: $e');
      if (mounted) {
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
    // The link is up (setting up OR streaming) — the active device's row is
    // highlighted for both so the user can see progress and cancel a stuck
    // setup.
    final isLinkUp = bt.isLinkUp;

    // Whether the single link slot is occupied by the demo device (in any
    // state). The BLE status indicator must not report link states caused by
    // the demo device — it describes Bluetooth only — so the link state
    // passed to it below is gated on this.
    final isDemoLink = bt.link.isDemoDevice;
    final isDemoActive = isDemoLink && isLinkUp;

    // A *real* BLE link is "busy" whenever it is mid-transition, active, or
    // cooling down after a disconnect; device-row Connect buttons stay disabled
    // until the link returns to idle. This is what prevents the
    // disconnect→reconnect double-click race — including the web
    // post-disconnect settle window where the stack isn't yet ready to accept
    // a fresh connection. A demo-held link is deliberately NOT busy: the demo
    // yields automatically when a real connect starts (see
    // BleLinkManager.connectToDevice), so BLE rows stay enabled while it runs.
    final isBusy = bt.linkBusy && !isDemoLink;

    // The specific device currently in its post-disconnect cooldown window (web
    // only); its row shows "Please wait…" instead of "Connect".
    final coolingDownDeviceId = bt.isCoolingDown ? bt.link.deviceId : '';

    // The BLE device currently holding the link (empty when idle or when the
    // demo device holds it). Its row is highlighted and hoisted to the top of
    // the BLE list.
    final String activeBleDeviceId = (isLinkUp && !isDemoLink)
        ? bt.link.deviceId
        : '';

    // Reorder the discovered list so the active device is on top.
    final devices = List.of(bt.devices);
    final int activeIdx = devices.indexWhere(
      (d) => d.deviceId == activeBleDeviceId,
    );
    if (activeIdx > 0) {
      devices.insert(0, devices.removeAt(activeIdx));
    }
    // Defensive: the active device should always still be in the scan list
    // (scanning is blocked while a link is busy, so the list can't be cleared
    // out from under it), but if it ever isn't, synthesize its card from the
    // link itself rather than showing a connected device nowhere at all.
    final bool activeBleMissing = activeBleDeviceId.isNotEmpty && activeIdx < 0;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Devices', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),

          // BLE devices section — always shown so the page structure stays
          // predictable; the empty state lives inside it.
          const SectionHeader('BLE devices'),
          const SizedBox(height: 8),

          // Centered scan controls: status text + icon + Scan button. Flexible
          // lets long status text ellipsize on narrow screens instead of
          // overflowing.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: BluetoothIndicator(
                  // The demo device occupies the same single link slot, but
                  // this indicator reports Bluetooth state only — report idle
                  // while the demo holds the link.
                  linkState: isDemoLink ? BtLinkState.idle : bt.link.state,
                  state: bt.bluetoothState,
                  isScanning: bt.isScanning,
                  hasDevices: bt.devices.isNotEmpty,
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
          const SizedBox(height: 8),

          if (devices.isEmpty && !activeBleMissing && !bt.isScanning)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
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
                      'Tap Scan to search for nearby devices',
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                  ],
                ),
              ),
            ),

          if (activeBleMissing)
            _activeDeviceCard(
              context,
              bt,
              icon: isStreaming
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_searching,
              title: bt.connectedDeviceName,
              subtitle: _activeBleSubtitle(bt),
            ),

          for (final device in devices)
            if (device.deviceId == activeBleDeviceId)
              _activeDeviceCard(
                context,
                bt,
                icon: isStreaming
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_searching,
                title: bt.connectedDeviceName,
                subtitle: _activeBleSubtitle(bt),
              )
            else
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
                    onPressed: isBusy
                        ? null
                        : () => _connectWithFeedback(
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
          if (isDemoActive)
            _activeDeviceCard(
              context,
              bt,
              icon: Icons.science,
              title: 'Demo Device',
              subtitle: 'Connected  •  Simulated data',
            )
          else
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: ListTile(
                leading: const Icon(Icons.science, color: Colors.teal),
                title: const Text('Demo Device'),
                subtitle: const Text('Simulated data — no hardware'),
                trailing: FilledButton(
                  onPressed: isBusy
                      ? null
                      : () => _connectWithFeedback(
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

  /// Subtitle for the active BLE device's highlighted card: setup progress
  /// while the link is being brought up, then live RSSI once streaming.
  String _activeBleSubtitle(BleLinkManager bt) {
    if (!bt.isStreaming) {
      return 'Setting up…';
    }
    return bt.connectedRssi != null
        ? 'Connected  •  RSSI: ${bt.connectedRssi} dBm'
        : 'Connected';
  }

  /// Highlighted card for the device currently holding the link (BLE or demo).
  /// Rendered in place of the device's normal row, at the top of its section,
  /// with a Disconnect action instead of Connect.
  Widget _activeDeviceCard(
    BuildContext context,
    BleLinkManager bt, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.primary, width: 1.5),
      ),
      child: ListTile(
        leading: Icon(icon, color: scheme.onPrimaryContainer),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: scheme.onPrimaryContainer,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
        trailing: TextButton(
          // Explicit foreground: the default (scheme.primary) can blend into
          // the primaryContainer card background in some themes;
          // onPrimaryContainer is the guaranteed-contrast pair.
          style: TextButton.styleFrom(
            foregroundColor: scheme.onPrimaryContainer,
          ),
          // Disabled while the disconnect is in flight so the button
          // truthfully reflects the in-progress teardown.
          onPressed: bt.isDisconnecting
              ? null
              : () async {
                  await bt.disconnectSelectedDevice();
                },
          child: Text(bt.isDisconnecting ? 'Disconnecting…' : 'Disconnect'),
        ),
      ),
    );
  }
}
