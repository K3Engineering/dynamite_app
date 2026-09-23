import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/bt_scan.dart';
import '../services/ble_link_manager.dart';
import '../services/demo_device.dart';
import '../services/feed_health_tracker.dart';
import '../utils/format.dart';
import '../widgets/bt_icon.dart';
import '../widgets/empty_placeholder.dart';
import '../widgets/feed_health_indicator.dart';
import '../widgets/rssi_indicator.dart';
import '../widgets/section_header.dart';
import '../widgets/snackbars.dart';
import '../status_colors.dart';
import '../widgets/wide_layout.dart';

class DevicesTab extends StatelessWidget {
  const DevicesTab({super.key, required this.onGoToSettings});

  /// The active row's gear action; the app shell owns the tab index.
  final VoidCallback onGoToSettings;

  @override
  Widget build(BuildContext context) {
    final bt = context.watch<BleLinkManager>();
    final scheme = Theme.of(context).colorScheme;

    // The top indicator reflects adapter/scan state only; link state lives on
    // the rows.
    final status = Theme.of(context).extension<StatusColors>()!;
    final visual = btAdapterScanVisual(
      availability: bt.bluetoothState,
      isScanning: bt.isScanning,
      hasConnectableDevices: bt.devices.isNotEmpty && !bt.linkBusy,
      status: status,
      colors: scheme,
    );

    final isEmpty = bt.devices.isEmpty;
    final showEmptyBlock = isEmpty && !bt.isScanning;

    final indicatorMode = topIndicatorMode(
      availability: bt.bluetoothState,
      isScanning: bt.isScanning,
      emptyBlockVisible: showEmptyBlock,
    );

    // Partition rows stably: fresh keep scan order, stale sink and sort by
    // recency. The active row is never stale.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final activeId = bt.activeDeviceId;
    final visuals = <String, InactiveRowVisual>{
      for (final d in bt.devices)
        d.deviceId: inactiveRowVisual(
          scanRssi: d.rssi,
          scanTs: d.timestamp,
          lastAliveMs: bt.lastAliveMs(d.deviceId),
          nowMs: nowMs,
          supportsScanRssi: bt.supportsScanRssi,
          // Transient beats history: the reconnect embargo outranks the last
          // outcome.
          reconnectHint: bt.reconnectPendingFor(d.deviceId)
              ? 'Waiting after disconnect…'
              : null,
          failureHint: switch (bt.connectFailureFor(d.deviceId)) {
            final kind? => connectFailureHint(kind, isWeb: kIsWeb),
            null => switch (bt.setupFailureFor(d.deviceId)) {
              final detail? => 'Setup failed: $detail',
              null => switch (bt.lastDisconnectErrorFor(d.deviceId)) {
                final err? => 'Disconnected: $err',
                null => null,
              },
            },
          },
          status: status,
          colors: scheme,
        ),
    };
    final freshRows = <DiscoveredDevice>[];
    final staleRows = <DiscoveredDevice>[];
    for (final d in bt.devices) {
      (d.deviceId != activeId &&
                  visuals[d.deviceId]!.mood == InactiveRowMood.stale
              ? staleRows
              : freshRows)
          .add(d);
    }
    staleRows.sort(
      (a, b) => compareStaleRowsByRecency(
        bt.lastAliveMs(a.deviceId),
        bt.lastAliveMs(b.deviceId),
      ),
    );

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: EdgeInsets.symmetric(
            horizontal: contentSideInset(constraints.maxWidth),
            vertical: 16,
          ),
          children: [
            Text('Devices', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 16),

            const SectionHeader('BLE devices'),
            const SizedBox(height: 8),

            Padding(
              padding: const EdgeInsets.only(left: 4, right: 28),
              child: Row(
                children: [
                  Expanded(
                    child: BluetoothIndicator(
                      visual: visual,
                      mode: indicatorMode,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: deviceActionButtonWidth,
                    child: FilledButton(
                      // TODO(ux): see BleLinkManager._startScan — starting a scan
                      // while streaming kills the active link (and any in-progress
                      // recording). Decide disable-vs-confirm.
                      onPressed: () => _scanWithFeedback(context, bt),
                      child: Text(bt.isScanning ? 'Stop' : 'Scan'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            if (showEmptyBlock) _buildEmptyBlock(visual, bt.bluetoothState),

            // The active row is found in the scan list, which no path clears
            // while a link is up.
            for (final device in [...freshRows, ...staleRows])
              device.deviceId == activeId
                  ? _ActiveDeviceRow(
                      name: device.name ?? 'Unknown device',
                      model: bt.connectedDeviceInfo?.model,
                      linkState: bt.linkState,
                      connectedRssi: bt.connectedRssi,
                      onDisconnect: bt.disconnectSelectedDevice,
                      onGoToSettings: onGoToSettings,
                    )
                  : _InactiveDeviceRow(
                      name: device.name ?? 'Unknown device',
                      visual: visuals[device.deviceId]!,
                      canConnect: bt.canConnectTo(device.deviceId),
                      onConnect: () => _connectWithFeedback(
                        () => bt.connectToDevice(device.deviceId),
                        device.name ?? 'device',
                      ),
                    ),
            const SizedBox(height: 16),

            // Demo devices section.
            const SectionHeader('Demo devices'),
            const SizedBox(height: 8),
            if (bt.isSimulated && bt.linkState != BtLinkState.idle)
              _ActiveDeviceRow(
                name: 'Demo Device',
                icon: Icons.science,
                model: bt.connectedDeviceInfo?.model,
                linkState: bt.linkState,
                connectedRssi: null,
                onDisconnect: bt.disconnectSelectedDevice,
                onGoToSettings: onGoToSettings,
              )
            else
              _InactiveDeviceRow(
                name: 'Demo Device',
                visual: (
                  mood: InactiveRowMood.normal,
                  icon: Icons.science,
                  iconColor: Colors.teal,
                  subtitle: 'Simulated data — no hardware',
                  subtitleColor: null,
                  cardColor: null,
                  titleColor: null,
                ),
                canConnect: bt.canConnectTo(demoDeviceId),
                onConnect: () =>
                    _connectWithFeedback(bt.connectToDemoDevice, 'Demo Device'),
              ),
          ],
        ),
      ),
    );
  }

  /// The state-aware empty block.
  Widget _buildEmptyBlock(BtStatusVisual visual, BtAvailability availability) {
    final (title, hint) = switch (availability) {
      BtAvailability.poweredOn => (
        'No devices found',
        'Tap Scan to search for nearby devices',
      ),
      BtAvailability.poweredOff => (
        visual.label,
        'Turn on Bluetooth to find devices',
      ),
      BtAvailability.unauthorized => (
        visual.label,
        'Grant Bluetooth permission to find devices',
      ),
      BtAvailability.unsupported => (
        visual.label,
        unsupportedHint(isWeb: kIsWeb),
      ),
      BtAvailability.unknown || BtAvailability.resetting => (
        visual.label,
        'This should only take a moment',
      ),
    };
    final poweredOn = availability == BtAvailability.poweredOn;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: EmptyPlaceholder(
        icon: poweredOn ? Icons.bluetooth_searching : visual.icon,
        // Neutral for the not-a-failure "no devices found"; the failure
        // modes keep the visual's semantic color.
        color: poweredOn ? null : visual.color,
        title: title,
        hint: hint,
      ),
    );
  }
}

/// Map a connect-failure [kind] to the per-row hint.
String connectFailureHint(
  ConnectFailureKind kind, {
  required bool isWeb,
}) => switch (kind) {
  ConnectFailureKind.failed =>
    isWeb
        ? "Couldn't connect — tap Scan and pick it again"
        : "Couldn't connect — check that it's on, nearby, and not connected to another device",
  ConnectFailureKind.timeout =>
    'Timed out — check that the device is on, nearby, and not connected to another device',
};

/// The empty block's hint for [BtAvailability.unsupported], per platform.
String unsupportedHint({required bool isWeb}) => isWeb
    ? "This browser can't use Bluetooth. Try Chrome or Edge on a computer, Chrome on Android, or the native Android/iOS app."
    : 'This device reports no Bluetooth support. The app is available for Android and iOS, as a web app in Chrome on Android, and in Chrome or Edge on a computer.';

/// The liveness subtitle for inactive BLE rows (RSSI when fresh, else "Last
/// seen" age).
({String text, bool stale})? bleRowSubtitle({
  required int? scanRssi,
  required int? scanTs,
  required int? lastAliveMs,
  required int nowMs,
  required bool supportsScanRssi,
}) {
  final stamp = lastAliveMs;
  if (stamp == null) {
    final text = scanRssi != null
        ? 'RSSI: $scanRssi dBm'
        : (supportsScanRssi ? 'RSSI: --' : null);
    return text == null ? null : (text: text, stale: false);
  }
  final age = Duration(milliseconds: nowMs - stamp);
  final stale = age > BleLinkManager.deviceStaleAfter;
  final advertFresh =
      scanTs != null &&
      Duration(milliseconds: nowMs - scanTs) <= BleLinkManager.deviceStaleAfter;
  if (!stale && supportsScanRssi && advertFresh) {
    return (
      text: scanRssi != null ? 'RSSI: $scanRssi dBm' : 'RSSI: --',
      stale: false,
    );
  }
  // One label on both platforms; "Last connected" read wrong for a stamp taken
  // at disconnect time.
  return (text: 'Last seen ${formatRelativeAge(age)}', stale: stale);
}

/// Stale rows: most recently seen first. A null stamp (defensive) sinks.
int compareStaleRowsByRecency(int? aAliveMs, int? bAliveMs) =>
    (bAliveMs ?? 0).compareTo(aAliveMs ?? 0);

/// The inactive row's presentation state. Priority: reconnect window >
/// failure > staleness > normal.
enum InactiveRowMood { normal, stale, failed }

/// An inactive row's resolved visual; null colors mean "theme default".
typedef InactiveRowVisual = ({
  InactiveRowMood mood,
  IconData icon,
  Color iconColor,
  String? subtitle,
  Color? subtitleColor,
  Color? cardColor,
  Color? titleColor,
});

/// Shared action-button width, sized to fit "Disconnecting…".
const double deviceActionButtonWidth = 136;

/// Card width below which the active row moves its buttons onto their own row.
const double _activeRowSingleRowWidth = 480;

/// Map platform/liveness/failure state to the inactive row's visual.
InactiveRowVisual inactiveRowVisual({
  required int? scanRssi,
  required int? scanTs,
  required int? lastAliveMs,
  required int nowMs,
  required bool supportsScanRssi,
  required String? reconnectHint,
  required String? failureHint,
  required StatusColors status,
  required ColorScheme colors,
}) {
  // Web only: a just-disconnected device not ready to reconnect. Not an error,
  // and the mood stays normal so it keeps fresh-group ordering.
  if (reconnectHint != null) {
    return (
      mood: InactiveRowMood.normal,
      icon: Icons.bluetooth_searching,
      iconColor: status.linkActive,
      subtitle: reconnectHint,
      subtitleColor: null,
      cardColor: null,
      titleColor: null,
    );
  }
  if (failureHint != null) {
    return (
      mood: InactiveRowMood.failed,
      icon: Icons.error_outline,
      iconColor: colors.error,
      subtitle: failureHint,
      subtitleColor: colors.error,
      cardColor: null,
      titleColor: null,
    );
  }
  final freshness = bleRowSubtitle(
    scanRssi: scanRssi,
    scanTs: scanTs,
    lastAliveMs: lastAliveMs,
    nowMs: nowMs,
    supportsScanRssi: supportsScanRssi,
  );
  if (freshness != null && freshness.stale) {
    final dim = colors.onSurface.withValues(alpha: 0.38);
    return (
      mood: InactiveRowMood.stale,
      icon: Icons.bluetooth,
      iconColor: dim,
      subtitle: freshness.text,
      subtitleColor: dim,
      cardColor: colors.surfaceContainerHighest,
      titleColor: dim,
    );
  }
  return (
    mood: InactiveRowMood.normal,
    icon: Icons.bluetooth,
    iconColor: colors.outline,
    subtitle: freshness?.text,
    subtitleColor: null,
    cardColor: null,
    titleColor: null,
  );
}

/// Run a connect attempt; failures surface as a per-row marker, so this only
/// logs the detail.
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

/// Run a scan toggle, surfacing a genuine start failure as a snackbar. Web
/// picker dismissals are already swallowed by the manager.
Future<void> _scanWithFeedback(BuildContext context, BleLinkManager bt) async {
  try {
    await bt.toggleScan();
  } catch (e) {
    debugPrint('Scan toggle failed: $e');
    if (context.mounted) {
      showErrorSnackBar(
        ScaffoldMessenger.of(context),
        'Failed to start scan: $e',
      );
    }
  }
}

/// An inactive device row, declarative over a precomputed [InactiveRowVisual].
/// The Connect button stays enabled across moods and is disabled only per
/// [canConnect].
class _InactiveDeviceRow extends StatelessWidget {
  const _InactiveDeviceRow({
    required this.name,
    required this.visual,
    required this.canConnect,
    required this.onConnect,
  });

  final String name;

  final InactiveRowVisual visual;

  /// From [BleLinkManager.canConnectTo].
  final bool canConnect;

  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final subtitle = visual.subtitle;
    return Card(
      color: visual.cardColor,
      child: ListTile(
        leading: Icon(visual.icon, color: visual.iconColor),
        title: Text(
          name,
          style: visual.titleColor == null
              ? null
              : TextStyle(color: visual.titleColor),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                // Merges over the tile's subtitle style, overriding only color.
                style: visual.subtitleColor == null
                    ? null
                    : TextStyle(color: visual.subtitleColor),
              ),
        // Fixed width: same column/shape as the Scan and Disconnect buttons
        // (see [deviceActionButtonWidth]).
        trailing: SizedBox(
          width: deviceActionButtonWidth,
          child: FilledButton(
            onPressed: canConnect ? onConnect : null,
            child: const Text('Connect'),
          ),
        ),
      ),
    );
  }
}

/// The active row's Cancel/Disconnect style: OutlinedButtons don't inherit the
/// tile's themed foreground, so declare it; reduced padding fits the label.
ButtonStyle activeRowActionButtonStyle({required Color onContainer}) =>
    OutlinedButton.styleFrom(
      foregroundColor: onContainer,
      disabledForegroundColor: onContainer.withValues(alpha: 0.5),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    ).copyWith(
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.disabled)
              ? onContainer.withValues(alpha: 0.5)
              : onContainer,
        ),
      ),
    );

/// The active device row.
class _ActiveDeviceRow extends StatelessWidget {
  const _ActiveDeviceRow({
    required this.name,
    this.icon,
    this.model,
    required this.linkState,
    required this.connectedRssi,
    required this.onDisconnect,
    required this.onGoToSettings,
  });

  final String name;

  /// Leading icon override; null uses the state-driven Bluetooth icon.
  final IconData? icon;

  /// The device model from the connect-time DIS read; null until it lands.
  final String? model;

  final BtLinkState linkState;

  /// Live RSSI; null until the first read.
  final int? connectedRssi;

  final VoidCallback onDisconnect;

  /// The gear button's action.
  final VoidCallback onGoToSettings;

  @override
  Widget build(BuildContext context) {
    final visual = btActiveLinkVisual(
      linkState: linkState,
      status: Theme.of(context).extension<StatusColors>()!,
    );
    final scheme = Theme.of(context).colorScheme;
    final onContainer = scheme.onPrimaryContainer;
    final isConnecting = linkState == BtLinkState.connecting;
    final isDisconnecting = linkState == BtLinkState.disconnecting;

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Device settings',
          visualDensity: VisualDensity.compact,
          onPressed: onGoToSettings,
        ),
        SizedBox(
          width: deviceActionButtonWidth,
          child: OutlinedButton(
            style: activeRowActionButtonStyle(onContainer: onContainer),
            onPressed: isDisconnecting ? null : onDisconnect,
            child: Text(
              isDisconnecting
                  ? 'Disconnecting…'
                  : isConnecting
                  ? 'Cancel'
                  : 'Disconnect',
            ),
          ),
        ),
      ],
    );

    return Card(
      color: scheme.primaryContainer,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Wide: buttons ride in the tile's trailing. Narrow: the trailing
          // would leave no text lane, so they move to their own row.
          final wide = constraints.maxWidth >= _activeRowSingleRowWidth;
          final tile = ListTile(
            selected: true,
            minLeadingWidth: 28,
            horizontalTitleGap: 8,
            leading: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon ?? visual.icon, color: visual.color),
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
            // One Text.rich so the label wraps at word boundaries; a Row would
            // squeeze it to near-zero width on a phone.
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: visual.label),
                      if (model != null) TextSpan(text: ' • $model'),
                      if (connectedRssi != null) ...[
                        const TextSpan(text: ' • '),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: RssiIndicator(
                            rssi: connectedRssi,
                            color: onContainer,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                FeedHealthIndicator(
                  health: context.read<FeedHealthTracker>().health,
                ),
              ],
            ),
            trailing: wide ? actions : null,
          );
          if (wide) return tile;
          return Column(
            children: [
              tile,
              Padding(
                padding: const EdgeInsets.only(right: 24, bottom: 8),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: actions,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
