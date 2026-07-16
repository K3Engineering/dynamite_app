import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart'
    show AvailabilityState, BleDevice;

import '../services/ble_link_manager.dart';
import '../widgets/bt_icon.dart';

const double _gap = 12;

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

    final bool isBtOff = _isBluetoothOff(bt.bluetoothState);
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async {
          if (!bt.isScanning && !isBtOff) {
            await bt.toggleScan();
          }
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Connect a load cell to begin',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: _gap),

            if (isBtOff) ...[
              _BluetoothOffBanner(
                state: bt.bluetoothState,
                onEnable: bt.requestEnableBluetooth,
              ),
              const SizedBox(height: _gap),
            ],

            BluetoothIndicator(
              // The demo device occupies the same single link slot, but this
              // indicator reports Bluetooth state only — report idle while the
              // demo holds the link.
              linkState: isDemoLink ? BtLinkState.idle : bt.link.state,
              state: bt.bluetoothState,
              isScanning: bt.isScanning,
              hasDevices: bt.devices.isNotEmpty,
            ),
            const SizedBox(height: _gap),

            Center(
              child: FilledButton.icon(
                onPressed: () async {
                  await bt.toggleScan();
                },
                icon: bt.isScanning
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.search),
                label: Text(bt.isScanning ? 'Stop' : 'Scan'),
              ),
            ),
            const SizedBox(height: _gap),

            if (devices.isEmpty && !activeBleMissing && !bt.isScanning)
              _EmptyState(
                onTryDemo: (!isDemoActive && !isBusy)
                    ? () => _connectWithFeedback(
                        bt.connectToDemoDevice,
                        'Demo Device',
                      )
                    : null,
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
                rssi: bt.connectedRssi,
                pillLabel: _activeStatusLabel(bt),
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
                  rssi: bt.connectedRssi,
                  pillLabel: _activeStatusLabel(bt),
                )
              else
                _BleDeviceCard(
                  device: device,
                  isBusy: isBusy,
                  isCoolingDown: device.deviceId == coolingDownDeviceId,
                  onConnect: () => _connectWithFeedback(
                    () => bt.connectToDevice(device.deviceId),
                    device.name ?? 'device',
                  ),
                ),
            const SizedBox(height: _gap),

            const _DemoDivider(),
            const SizedBox(height: _gap),

            if (isDemoActive)
              _activeDeviceCard(
                context,
                bt,
                icon: Icons.science,
                title: 'Demo Device',
                subtitle: 'Connected  •  Simulated data',
                pillLabel: 'Demo',
                pillForeground: Colors.white,
                pillBackground: Colors.teal,
              )
            else
              _DemoCard(
                isBusy: isBusy,
                onConnect: () =>
                    _connectWithFeedback(bt.connectToDemoDevice, 'Demo Device'),
              ),
          ],
        ),
      ),
    );
  }

  bool _isBluetoothOff(AvailabilityState state) {
    switch (state) {
      case AvailabilityState.poweredOff:
      case AvailabilityState.unauthorized:
      case AvailabilityState.unsupported:
        return true;
      default:
        return false;
    }
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

  /// Compact status label for the active card's pill badge.
  String _activeStatusLabel(BleLinkManager bt) {
    if (bt.isDisconnecting) return 'Disconnecting…';
    if (!bt.isStreaming) return 'Setting up…';
    return 'Connected';
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
    int? rssi,
    String? pillLabel,
    Color? pillForeground,
    Color? pillBackground,
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
        title: Row(
          children: [
            Flexible(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            if (pillLabel != null) ...[
              const SizedBox(width: 8),
              _Pill(
                label: pillLabel,
                foreground: pillForeground ?? scheme.onPrimaryContainer,
                background:
                    pillBackground ??
                    scheme.onPrimaryContainer.withValues(alpha: 0.15),
              ),
            ],
          ],
        ),
        subtitle: Row(
          children: [
            Flexible(
              child: Text(
                subtitle,
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
            ),
            if (rssi != null) ...[
              const SizedBox(width: 8),
              _RssiBars(
                rssi: rssi,
                activeColor: scheme.onPrimaryContainer,
                inactiveColor: scheme.onPrimaryContainer.withValues(alpha: 0.3),
              ),
            ],
          ],
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

class _BluetoothOffBanner extends StatelessWidget {
  final AvailabilityState state;
  final VoidCallback onEnable;

  const _BluetoothOffBanner({required this.state, required this.onEnable});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    String message;
    switch (state) {
      case AvailabilityState.poweredOff:
        message = 'Bluetooth is off';
      case AvailabilityState.unauthorized:
        message = 'Bluetooth permission needed';
      case AvailabilityState.unsupported:
        message = 'Bluetooth not supported';
      default:
        message = 'Bluetooth unavailable';
    }
    final bool canEnable = state != AvailabilityState.unsupported;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.bluetooth_disabled,
            color: scheme.onErrorContainer,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: text.bodyMedium?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
          if (canEnable)
            TextButton(
              onPressed: onEnable,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onErrorContainer,
              ),
              child: const Text('Enable'),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final Future<void> Function()? onTryDemo;

  const _EmptyState({this.onTryDemo});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.bluetooth_searching, size: 64, color: scheme.outline),
            const SizedBox(height: _gap),
            Text(
              'No devices found',
              style: text.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            if (onTryDemo != null)
              GestureDetector(
                onTap: onTryDemo,
                child: Text(
                  'No hardware? Try the demo device.',
                  style: TextStyle(
                    color: scheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: scheme.primary,
                  ),
                ),
              )
            else
              Text(
                'Tap Scan to search for nearby devices',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

class _BleDeviceCard extends StatelessWidget {
  final BleDevice device;
  final bool isBusy;
  final bool isCoolingDown;
  final Future<void> Function() onConnect;

  const _BleDeviceCard({
    required this.device,
    required this.isBusy,
    required this.isCoolingDown,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        visualDensity: VisualDensity.compact,
        leading: _RssiBars(rssi: device.rssi),
        title: Text(device.name ?? 'Unknown device'),
        subtitle: Text(
          isCoolingDown
              ? 'Please wait…'
              : (device.rssi != null ? 'RSSI: ${device.rssi} dBm' : 'RSSI: --'),
          style: TextStyle(
            fontStyle: isCoolingDown ? FontStyle.italic : FontStyle.normal,
            color: isCoolingDown ? scheme.onSurfaceVariant : null,
          ),
        ),
        trailing: OutlinedButton(
          // Disabled whenever a link is busy (connecting/connected/
          // disconnecting) so we never issue a connect against a link
          // that is still tearing down.
          onPressed: isBusy ? null : onConnect,
          child: const Text('Connect'),
        ),
      ),
    );
  }
}

class _DemoCard extends StatelessWidget {
  final bool isBusy;
  final Future<void> Function() onConnect;

  const _DemoCard({required this.isBusy, required this.onConnect});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: ListTile(
        visualDensity: VisualDensity.compact,
        leading: const Icon(Icons.science, color: Colors.teal),
        title: const Row(
          children: [
            Flexible(child: Text('Demo Device')),
            SizedBox(width: 8),
            _Pill(
              label: 'Demo',
              foreground: Colors.white,
              background: Colors.teal,
            ),
          ],
        ),
        subtitle: const Text('Simulated data — no hardware'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message:
                  'Simulated load-cell data — no hardware required. '
                  'Useful for trying the app.',
              child: Icon(
                Icons.info_outline,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: isBusy ? null : onConnect,
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DemoDivider extends StatelessWidget {
  const _DemoDivider();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            'Demo',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}

class _RssiBars extends StatelessWidget {
  final int? rssi;
  final Color? activeColor;
  final Color? inactiveColor;

  const _RssiBars({this.rssi, this.activeColor, this.inactiveColor});

  int _strength(int? rssi) {
    if (rssi == null) return 0;
    if (rssi >= -60) return 3;
    if (rssi >= -80) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onColor = activeColor ?? scheme.primary;
    final offColor = inactiveColor ?? scheme.outlineVariant;
    final strength = _strength(rssi);
    return Semantics(
      label: rssi != null ? 'Signal $rssi dBm' : 'Signal unknown',
      child: Tooltip(
        message: rssi != null ? 'RSSI: $rssi dBm' : 'RSSI: --',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (int i = 0; i < 3; i++)
              Container(
                margin: const EdgeInsets.only(right: 2),
                width: 4,
                height: 6.0 + (i * 4),
                decoration: BoxDecoration(
                  color: i < strength ? onColor : offColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color foreground;
  final Color background;

  const _Pill({
    required this.label,
    required this.foreground,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
