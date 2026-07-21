import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

import '../services/ble_link_manager.dart';
import '../widgets/bt_icon.dart';
import '../widgets/empty_placeholder.dart';
import '../widgets/section_header.dart';
import '../widgets/status_colors.dart';
import 'app_shell.dart';

class DevicesTab extends StatelessWidget {
  const DevicesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final bt = context.watch<BleLinkManager>();

    final visual = btStatusVisual(
      linkState: bt.link.state,
      availability: bt.bluetoothState,
      isScanning: bt.isScanning,
      hasDevices: bt.devices.isNotEmpty,
      status: Theme.of(context).extension<StatusColors>()!,
      colors: Theme.of(context).colorScheme,
    );

    final isEmpty = bt.devices.isEmpty;
    // The compact Bluetooth status row shows once there's content (devices
    // listed, or a link in flight/connected). While empty it shows only
    // during a scan — where the placeholder (which can't spin) yields to the
    // spinning status row.
    final showStatusRow = !isEmpty || bt.isScanning;
    // The big empty block is the empty-state voice for genuinely idle states
    // (radio off / permission / no devices found) — not during a scan.
    final showEmptyBlock = isEmpty && !bt.isScanning;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Text('Devices', style: Theme.of(context).textTheme.headlineSmall),
              // Reserved trailing slot: nothing renders here for now. This is
              // where a future top-of-page status item (in the spirit of the
              // Live tab's status banner) would go.
              const Spacer(),
            ],
          ),
          const SizedBox(height: 16),

          // BLE devices section. The Scan button lives on the section header;
          // the Bluetooth status readout sits on its own row beneath it so the
          // variable-width status text has room and never fights the button.
          SectionHeader(
            'BLE devices',
            trailing: FilledButton.tonal(
              // TODO(ux): see BleLinkManager._startScan — starting a scan
              // while streaming kills the active link (and any in-progress
              // recording). Decide disable-vs-confirm.
              onPressed: () async {
                await bt.toggleScan();
              },
              child: Text(bt.isScanning ? 'Stop' : 'Scan'),
            ),
          ),
          const SizedBox(height: 8),

          if (showStatusRow)
            Align(
              alignment: Alignment.centerLeft,
              child: BluetoothIndicator(
                linkState: bt.link.state,
                state: bt.bluetoothState,
                isScanning: bt.isScanning,
                hasDevices: bt.devices.isNotEmpty,
              ),
            ),

          if (showEmptyBlock) _buildEmptyBlock(visual),

          for (final device in bt.devices)
            _DeviceRow(
              name: device.name ?? 'Unknown device',
              scanRssi: device.rssi,
              inactiveIcon: Icons.bluetooth,
              inactiveIconColor: Theme.of(context).colorScheme.outline,
              isActive: device.deviceId == bt.link.deviceId,
              linkState: bt.link.state,
              connectedRssi: bt.connectedRssi,
              linkBusy: bt.linkBusy,
              isCoolingDown:
                  bt.isCoolingDown && device.deviceId == bt.link.deviceId,
              onConnect: () => _connectWithFeedback(
                context,
                () => bt.connectToDevice(device.deviceId),
                device.name ?? 'device',
              ),
              onDisconnect: bt.disconnectSelectedDevice,
            ),
          const SizedBox(height: 16),

          // Demo devices section — simulated hardware, kept at the bottom so
          // real BLE devices get top billing. Rendered through the same
          // _DeviceRow so it reflects connected state inline like a BLE row.
          const SectionHeader('Demo devices'),
          const SizedBox(height: 8),
          _DeviceRow(
            name: 'Demo Device',
            scanRssi: null,
            inactiveIcon: Icons.science,
            inactiveIconColor: Colors.teal,
            isActive: bt.link.isDemoDevice && bt.link.state != BtLinkState.idle,
            linkState: bt.link.state,
            connectedRssi: null,
            linkBusy: bt.linkBusy,
            isCoolingDown: false,
            inactiveSubtitle: 'Simulated data — no hardware',
            onConnect: () => _connectWithFeedback(
              context,
              bt.connectToDemoDevice,
              'Demo Device',
            ),
            onDisconnect: bt.disconnectSelectedDevice,
          ),
        ],
      ),
    );
  }

  /// The big state-aware empty block: the single empty-state voice, with
  /// icon/title/hint derived from BLE state (radio off / permission / no
  /// devices found) so it never claims "tap Scan" when scanning can't work.
  Widget _buildEmptyBlock(BtStatusVisual visual) {
    final (icon, title, hint) = switch (visual.label) {
      'Bluetooth is off' => (
        Icons.bluetooth_disabled,
        'Bluetooth is off',
        'Turn on Bluetooth to find devices',
      ),
      'Bluetooth permission needed' => (
        Icons.bluetooth_disabled,
        'Bluetooth permission needed',
        'Grant Bluetooth permission to find devices',
      ),
      'Bluetooth not supported' => (
        Icons.bluetooth_disabled,
        'Bluetooth not supported',
        'This device cannot use Bluetooth',
      ),
      _ => (
        Icons.bluetooth_searching,
        'No devices found',
        'Tap Scan to search for nearby devices',
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: EmptyPlaceholder(icon: icon, title: title, hint: hint),
    );
  }
}

/// Run a connect attempt, surfacing a failure as a snackbar naming
/// [deviceName] with the underlying error detail (timeout vs GATT error vs
/// user-cancelled web picker are wildly different diagnoses). Connect buttons
/// are already disabled while a link is busy, so this only handles the
/// rejected attempt itself.
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

/// A single device row, shared by the BLE and Demo sections. Renders one of
/// two forms:
///  * Inactive ([isActive] false): a plain row with a Connect button.
///  * Active ([isActive] true): a tinted row carrying the live link state
///    (spinner while connecting/setting up, connected icon when streaming),
///    the state + RSSI in the subtitle, a gear shortcut to Device settings,
///    and a state-aware Cancel/Disconnect button.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.name,
    required this.scanRssi,
    required this.inactiveIcon,
    required this.inactiveIconColor,
    required this.isActive,
    required this.linkState,
    required this.connectedRssi,
    required this.linkBusy,
    required this.isCoolingDown,
    this.inactiveSubtitle,
    required this.onConnect,
    required this.onDisconnect,
  });

  final String name;

  /// Scan-time RSSI for discovered BLE devices; null when unavailable (or for
  /// the demo device).
  final int? scanRssi;

  /// Leading icon/color used in the inactive form.
  final IconData inactiveIcon;
  final Color inactiveIconColor;

  /// Whether this row is the device's active link.
  final bool isActive;

  /// The active link's state (only meaningful when [isActive]).
  final BtLinkState linkState;

  /// Live polled RSSI for the connected device; null until first read.
  final int? connectedRssi;

  /// Whether any link transition is in flight (disables the Connect button).
  final bool linkBusy;

  /// Whether this row is in its post-disconnect reconnect-settle window
  /// (shows "Please wait…" instead of "Connect").
  final bool isCoolingDown;

  /// Fixed subtitle for the inactive form (e.g. the demo device's blurb).
  /// When null, the inactive form shows the scan RSSI.
  final String? inactiveSubtitle;

  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    if (!isActive) {
      return Card(
        child: ListTile(
          leading: Icon(inactiveIcon, color: inactiveIconColor),
          title: Text(name),
          subtitle: Text(
            inactiveSubtitle ??
                (scanRssi != null ? 'RSSI: $scanRssi dBm' : 'RSSI: --'),
          ),
          trailing: FilledButton(
            // Disabled whenever a link is busy so we never issue a connect
            // against a link that is still tearing down.
            onPressed: linkBusy ? null : onConnect,
            child: Text(isCoolingDown ? 'Please wait…' : 'Connect'),
          ),
        ),
      );
    }

    // Active row: reuse the shared, unit-tested state → visual mapping.
    final visual = btStatusVisual(
      linkState: linkState,
      availability: AvailabilityState.poweredOn, // a link is up → radio is on
      isScanning: false,
      hasDevices: true,
      status: Theme.of(context).extension<StatusColors>()!,
      colors: Theme.of(context).colorScheme,
    );
    final scheme = Theme.of(context).colorScheme;
    final isStreaming = linkState == BtLinkState.streaming;
    final isConnecting = linkState == BtLinkState.connecting;
    final isDisconnecting = linkState == BtLinkState.disconnecting;

    return Card(
      color: scheme.primaryContainer,
      child: ListTile(
        leading: Stack(
          alignment: Alignment.center,
          children: [
            Icon(visual.icon, color: visual.color),
            if (visual.showSpinner)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        title: Text(name),
        subtitle: Text(
          isStreaming && connectedRssi != null
              ? '${visual.label} • RSSI: $connectedRssi dBm'
              : visual.label,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Device settings',
              onPressed: () => context
                  .findAncestorStateOfType<AppShellState>()
                  ?.goToSettings(),
            ),
            TextButton(
              // Disabled while the disconnect is in flight so the button
              // truthfully reflects the in-progress teardown.
              onPressed: isDisconnecting ? null : onDisconnect,
              child: Text(
                isDisconnecting
                    ? 'Disconnecting…'
                    : isConnecting
                    ? 'Cancel'
                    : 'Disconnect',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
