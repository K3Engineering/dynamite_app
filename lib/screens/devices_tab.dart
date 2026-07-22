import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

import '../services/ble_link_manager.dart';
import '../widgets/bt_icon.dart';
import '../widgets/empty_placeholder.dart';
import '../widgets/rssi_indicator.dart';
import '../widgets/section_header.dart';
import '../widgets/status_colors.dart';
import 'app_shell.dart';

class DevicesTab extends StatelessWidget {
  const DevicesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final bt = context.watch<BleLinkManager>();

    final visual = btStatusVisual(
      linkState: bt.bleLinkState,
      availability: bt.bluetoothState,
      isScanning: bt.isScanning,
      hasDevices: bt.devices.isNotEmpty,
      status: Theme.of(context).extension<StatusColors>()!,
      colors: Theme.of(context).colorScheme,
    );

    final isEmpty = bt.devices.isEmpty;
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

          // BLE devices section. The status row leads with the Scan/Stop
          // button and carries the Bluetooth status readout (icon + label)
          // beside it, so the action and its effect ("Scanning for devices…")
          // sit together. Always visible — Scan is reachable in every state.
          const SectionHeader('BLE devices'),
          const SizedBox(height: 8),

          Row(
            children: [
              FilledButton.tonal(
                // TODO(ux): see BleLinkManager._startScan — starting a scan
                // while streaming kills the active link (and any in-progress
                // recording). Decide disable-vs-confirm.
                onPressed: () => _scanWithFeedback(context, bt),
                child: Text(bt.isScanning ? 'Stop' : 'Scan'),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: BluetoothIndicator(
                  linkState: bt.bleLinkState,
                  state: bt.bluetoothState,
                  isScanning: bt.isScanning,
                  hasDevices: bt.devices.isNotEmpty,
                ),
              ),
            ],
          ),

          if (showEmptyBlock) _buildEmptyBlock(visual, bt.bluetoothState),

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
              failureHint: switch (bt.connectFailureFor(device.deviceId)) {
                final kind? => connectFailureHint(kind),
                null => null,
              },
              onConnect: () => _connectWithFeedback(
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
            activeIcon: Icons.science,
            isActive: bt.link.isDemoDevice && bt.link.state != BtLinkState.idle,
            linkState: bt.link.state,
            connectedRssi: null,
            linkBusy: bt.linkBusy,
            isCoolingDown: false,
            inactiveSubtitle: 'Simulated data — no hardware',
            onConnect: () =>
                _connectWithFeedback(bt.connectToDemoDevice, 'Demo Device'),
            onDisconnect: bt.disconnectSelectedDevice,
          ),
        ],
      ),
    );
  }

  /// The big state-aware empty block: the single empty-state voice. Icon,
  /// color, and label come straight from the shared [btStatusVisual] mapping
  /// (this is where the failure modes live — the red "not supported" square,
  /// the permission-needed marker, "Starting up Bluetooth…"), so the page
  /// shows the exact adapter status and reason the compact indicator would.
  /// Only the powered-on case gets its own treatment: the indicator's action
  /// prompt ("Tap Scan to find devices") becomes a title + hint.
  Widget _buildEmptyBlock(
    BtStatusVisual visual,
    AvailabilityState availability,
  ) {
    final (icon, color, title, hint) = switch (availability) {
      AvailabilityState.poweredOn => (
        Icons.bluetooth_searching,
        null, // neutral — not a failure
        'No devices found',
        'Tap Scan to search for nearby devices',
      ),
      AvailabilityState.poweredOff => (
        visual.icon,
        visual.color,
        visual.label,
        'Turn on Bluetooth to find devices',
      ),
      AvailabilityState.unauthorized => (
        visual.icon,
        visual.color,
        visual.label,
        'Grant Bluetooth permission to find devices',
      ),
      AvailabilityState.unsupported => (
        visual.icon,
        visual.color,
        visual.label,
        'This device cannot use Bluetooth',
      ),
      AvailabilityState.unknown || AvailabilityState.resetting => (
        visual.icon,
        visual.color,
        visual.label,
        'This should only take a moment',
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: EmptyPlaceholder(
        icon: icon,
        color: color,
        title: title,
        hint: hint,
      ),
    );
  }
}

/// Map a recorded connect-failure [kind] to the per-row hint shown on the
/// Devices tab. [ConnectFailureKind.failed] covers Chrome's stale device
/// handle (a row left over from an earlier session rejects gatt.connect();
/// a fresh Scan + pick mints a new handle and is the actual fix) as well as
/// ordinary native refusals. Copy lives here in the UI layer; the manager
/// only records the kind (see [BleLinkManager.connectFailureFor]).
String connectFailureHint(ConnectFailureKind kind) => switch (kind) {
  ConnectFailureKind.failed => "Couldn't connect — tap Scan and pick it again",
  ConnectFailureKind.timeout =>
    'Timed out — make sure the device is on and nearby',
};

/// Run a connect attempt. A failure is surfaced by the manager as a per-row
/// marker (see [BleLinkManager.connectFailureFor]) — deliberately NOT a
/// snackbar, so rapid retries can't queue a stack of toasts — so this only
/// logs the underlying detail (timeout vs GATT error vs stale web handle are
/// wildly different diagnoses). Connect buttons are already disabled while a
/// link is busy, so this only handles the rejected attempt itself.
Future<void> _connectWithFeedback(
  Future<void> Function() connect,
  String deviceName,
) async {
  try {
    await connect();
  } catch (e) {
    debugPrint('Connect to $deviceName failed: $e');
  }
}

/// Run a scan toggle, surfacing a genuine start failure (a native radio
/// error, or a non-dismissal web error) as a snackbar — the scan analogue of
/// [_connectWithFeedback]. Web picker dismissals are swallowed by the manager
/// (see [BleLinkManager._startScan]), so a cancelled chooser has nothing to
/// report here.
Future<void> _scanWithFeedback(BuildContext context, BleLinkManager bt) async {
  try {
    await bt.toggleScan();
  } catch (e) {
    debugPrint('Scan toggle failed: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to start scan: $e')));
    }
  }
}

/// A single device row, shared by the BLE and Demo sections. Renders one of
/// two forms:
///  * Inactive ([isActive] false): a plain row with a Connect button. When
///    [failureHint] is set (the last connect attempt for this device failed),
///    the icon and subtitle switch to an error treatment showing the hint.
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
    this.activeIcon,
    required this.isActive,
    required this.linkState,
    required this.connectedRssi,
    required this.linkBusy,
    required this.isCoolingDown,
    this.inactiveSubtitle,
    this.failureHint,
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

  /// Leading icon override for the active form (e.g. the demo device's
  /// science beaker). When null, the state-driven Bluetooth icon from
  /// [btStatusVisual] is used.
  final IconData? activeIcon;

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

  /// User-facing hint for a failed connect attempt on this device (see
  /// [connectFailureHint]). When set, the inactive form shows it in the error
  /// color instead of the RSSI/subtitle, with an error leading icon; the
  /// Connect button stays enabled so the user can retry.
  final String? failureHint;

  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    if (!isActive) {
      final scheme = Theme.of(context).colorScheme;
      final hasFailure = failureHint != null;
      return Card(
        child: ListTile(
          leading: Icon(
            hasFailure ? Icons.error_outline : inactiveIcon,
            color: hasFailure ? scheme.error : inactiveIconColor,
          ),
          title: Text(name),
          subtitle: Text(
            failureHint ??
                inactiveSubtitle ??
                (scanRssi != null ? 'RSSI: $scanRssi dBm' : 'RSSI: --'),
            // Merges over the tile's subtitle style, overriding only color.
            style: hasFailure ? TextStyle(color: scheme.error) : null,
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
    final onContainer = scheme.onPrimaryContainer;
    final isConnecting = linkState == BtLinkState.connecting;
    final isDisconnecting = linkState == BtLinkState.disconnecting;

    // Division of labor: the Card owns the surface (paints the rounded
    // primaryContainer background — its native job), the selected ListTile
    // owns content (transparent itself; the app's listTileTheme supplies the
    // on-container color for the title, subtitle, and gear IconButton).
    return Card(
      color: scheme.primaryContainer,
      child: ListTile(
        selected: true,
        leading: Stack(
          alignment: Alignment.center,
          children: [
            Icon(activeIcon ?? visual.icon, color: visual.color),
            if (visual.showSpinner)
              SizedBox(
                width: 28,
                height: 28,
                // Spinners don't participate in tile theming; color it
                // explicitly or it defaults to primary on the dark surface.
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(onContainer),
                ),
              ),
          ],
        ),
        title: Text(name),
        subtitle: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(visual.label)),
            // Live RSSI (native only): null until the first poll lands —
            // and forever on web — in which case nothing renders.
            if (connectedRssi != null) ...[
              const Text(' • '),
              RssiIndicator(rssi: connectedRssi, color: onContainer),
            ],
          ],
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
              // TextButtons don't participate in tile theming either; without
              // this the label renders in primary on the primaryContainer
              // surface — invisible.
              style: TextButton.styleFrom(
                foregroundColor: onContainer,
                disabledForegroundColor: onContainer.withValues(alpha: 0.5),
              ),
              // Disabled while the disconnect is in flight so the button
              // truthfully reflects the in-progress teardown — and during the
              // post-disconnect cooldown, where the link is already down and
              // disconnectSelectedDevice would be an enabled no-op.
              onPressed: (isDisconnecting || isCoolingDown)
                  ? null
                  : onDisconnect,
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
