import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/bt_scan.dart';
import '../services/ble_link_manager.dart';
import '../services/feed_health_tracker.dart';
import '../utils/format.dart';
import '../widgets/bt_icon.dart';
import '../widgets/empty_placeholder.dart';
import '../widgets/feed_health_indicator.dart';
import '../widgets/rssi_indicator.dart';
import '../widgets/section_header.dart';
import '../widgets/snackbars.dart';
import '../widgets/status_colors.dart';
import '../widgets/wide_layout.dart';

class DevicesTab extends StatelessWidget {
  const DevicesTab({super.key, required this.onGoToSettings});

  /// The active device row's gear action: jumps to the Settings tab.
  /// Supplied by the app shell, which owns the tab index.
  final VoidCallback onGoToSettings;

  @override
  Widget build(BuildContext context) {
    final bt = context.watch<BleLinkManager>();
    final scheme = Theme.of(context).colorScheme;

    // Top indicator reflects only adapter/scan state; per-device link state
    // lives on the rows. We use raw linkBusy to withhold hints when ANY
    // link is busy, ensuring Connect buttons are disabled.
    final status = Theme.of(context).extension<StatusColors>()!;
    final visual = btStatusVisual(
      linkState: BtLinkState.idle,
      availability: bt.bluetoothState,
      isScanning: bt.isScanning,
      hasConnectableDevices: bt.devices.isNotEmpty && !bt.linkBusy,
      status: status,
      colors: scheme,
    );

    final isEmpty = bt.devices.isEmpty;
    // The big empty block is the empty-state voice for genuinely idle states
    // (radio off / permission / no devices found) — not during a scan.
    final showEmptyBlock = isEmpty && !bt.isScanning;

    // Top indicator modes: icon only for scan/failures, text-only for powered-on
    // hints, and fully silent while the big empty block is visible.
    final indicatorMode = topIndicatorMode(
      availability: bt.bluetoothState,
      isScanning: bt.isScanning,
      emptyBlockVisible: showEmptyBlock,
    );

    // Partition rows stably: fresh rows keep scan order, stale rows sink.
    // Active rows are never marked stale since they don't refresh while
    // streaming. The stale group is then ordered by recency (see
    // [compareStaleRowsByRecency]).
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final activeId = bt.link.deviceId;
    final visuals = <String, InactiveRowVisual>{
      for (final d in bt.devices)
        d.deviceId: inactiveRowVisual(
          scanRssi: d.rssi,
          // The advert receipt time — the freshness of the RSSI reading
          // itself (null on web, where no advertisement data exists).
          scanTs: d.timestamp,
          lastAliveMs: bt.lastAliveMs(d.deviceId),
          nowMs: nowMs,
          supportsScanRssi: bt.supportsScanRssi,
          // Transient beats history: while the reconnect embargo runs, the
          // row explains why its Connect button is disabled instead of
          // dwelling on the last outcome (it resurfaces at window end).
          reconnectHint: bt.reconnectPendingFor(d.deviceId)
              ? 'Waiting after disconnect…'
              : null,
          failureHint: switch (bt.connectFailureFor(d.deviceId)) {
            final kind? => connectFailureHint(kind, isWeb: kIsWeb),
            // No failed connect on record: show why the last link dropped,
            // when the platform gave a reason.
            null => switch (bt.lastDisconnectErrorFor(d.deviceId)) {
              final err? => 'Disconnected: $err',
              null => null,
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
    // Within the greyed group, most recently seen first — the "Last seen"
    // ages then increase monotonically down the list, and a just-staled
    // device (likely still of interest) leads it.
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

            // BLE devices section.
            const SectionHeader('BLE devices'),
            const SizedBox(height: 8),

            // Padding aligns the status readout and Scan button with the M3 Card
            // and ListTile contents below.
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
                    child: FilledButton.tonal(
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

            // The active link's row is found in the scan list. No current path
            // clears the list while a link is up without tearing the link down,
            // so the active row always exists.
            for (final device in [...freshRows, ...staleRows])
              device.deviceId == activeId
                  ? _ActiveDeviceRow(
                      name: device.name ?? 'Unknown device',
                      model: bt.connectedDeviceInfo?.model,
                      linkState: bt.link.state,
                      connectedRssi: bt.connectedRssi,
                      onDisconnect: bt.disconnectSelectedDevice,
                      onGoToSettings: onGoToSettings,
                    )
                  : _InactiveDeviceRow(
                      name: device.name ?? 'Unknown device',
                      visual: visuals[device.deviceId]!,
                      linkBusy: bt.linkBusy,
                      onConnect: () => _connectWithFeedback(
                        () => bt.connectToDevice(device.deviceId),
                        device.name ?? 'device',
                      ),
                    ),
            const SizedBox(height: 16),

            // Demo devices section — simulated hardware, kept at the bottom so
            // real BLE devices get top billing. Rendered through the same rows
            // so it reflects connected state inline like a BLE row.
            const SectionHeader('Demo devices'),
            const SizedBox(height: 8),
            if (bt.link.isSimulated && bt.link.state != BtLinkState.idle)
              _ActiveDeviceRow(
                name: 'Demo Device',
                icon: Icons.science,
                model: bt.connectedDeviceInfo?.model,
                linkState: bt.link.state,
                connectedRssi: null,
                onDisconnect: bt.disconnectSelectedDevice,
                onGoToSettings: onGoToSettings,
              )
            else
              _InactiveDeviceRow(
                name: 'Demo Device',
                // A fixed presentation: simulated hardware is never stale and
                // never fails to connect.
                visual: (
                  mood: InactiveRowMood.normal,
                  icon: Icons.science,
                  iconColor: Colors.teal,
                  subtitle: 'Simulated data — no hardware',
                  subtitleColor: null,
                  cardColor: null,
                  titleColor: null,
                ),
                linkBusy: bt.linkBusy,
                onConnect: () =>
                    _connectWithFeedback(bt.connectToDemoDevice, 'Demo Device'),
              ),
          ],
        ),
      ),
    );
  }

  /// The big state-aware empty block: the single empty-state voice. Icon
  /// and color come straight from the shared [btStatusVisual] mapping.
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

/// Map a recorded connect-failure [kind] to the per-row hint shown on the
/// Devices tab, including platform-specific web guidance (e.g., stale handles).
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
/// Web means the browser lacks Web Bluetooth (Firefox, Safari, every iOS
/// browser). Native means the device itself reports no Bluetooth
/// support — a baffling case with no clear recommendation, so the
/// copy avoids "try" and neutrally names every supported
/// surface. Copy lives here in the UI layer, like [connectFailureHint].
String unsupportedHint({required bool isWeb}) => isWeb
    ? "This browser can't use Bluetooth. Try Chrome or Edge on a computer, Chrome on Android, or the native Android/iOS app."
    : 'This device reports no Bluetooth support. The app is available for Android and iOS, as a web app in Chrome on Android, and in Chrome or Edge on a computer.';

/// Resolves the "liveness" subtitle for inactive BLE rows:
/// * No data: RSSI fallback if supported.
/// * Fresh: RSSI if advert is recent, otherwise "Last seen" age.
/// * Stale: "Last seen" age (hides stale RSSI).
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
  // One label on both platforms: on web "seen" can only mean a connection
  // stamp (no adverts exist there), and "Last connected" read wrong for a
  // stamp taken at disconnect time.
  return (text: 'Last seen ${formatRelativeAge(age)}', stale: stale);
}

/// Comparator for the stale (greyed) row group: most recently seen first, so
/// a just-staled device leads the group and long-gone ones sink — the rows'
/// "Last seen" ages then increase monotonically down the list. [aAliveMs] and
/// [bAliveMs] are the rows' [BleLinkManager.lastAliveMs] values; a null stamp
/// (defensive — a stale row always has one, see [bleRowSubtitle]) sorts
/// oldest, i.e. sinks to the end of the group.
int compareStaleRowsByRecency(int? aAliveMs, int? bAliveMs) =>
    (bAliveMs ?? 0).compareTo(aAliveMs ?? 0);

/// The inactive device row's presentation state, resolved by
/// [inactiveRowVisual]. Priority: the reconnect-settle window outranks a
/// recorded connect failure (transient beats history), which outranks
/// staleness (actionable beats maybe-gone), which outranks the normal look.
/// The mood also drives the Devices tab's row ordering (stale sinks last,
/// then ordered by recency — see [compareStaleRowsByRecency]).
enum InactiveRowMood { normal, stale, failed }

/// Everything an inactive device row displays, resolved from platform,
/// liveness, and failure state by [inactiveRowVisual] (a pure function — the
/// mapping is unit-tested; colors are supplied from the theme). Null colors
/// mean "theme default for that slot".
typedef InactiveRowVisual = ({
  InactiveRowMood mood,
  IconData icon,
  Color iconColor,
  String? subtitle,
  Color? subtitleColor,
  Color? cardColor,
  Color? titleColor,
});

/// Shared width for action buttons to maintain vertical alignment.
/// Sized to fit "Disconnecting…".
const double deviceActionButtonWidth = 136;

/// Map platform/liveness/failure state to the inactive row's full visual.
///
/// A stale row ("hasn't been active for a while") is de-emphasized: the
/// foreground dims to disabled emphasis and the card gets a subtle blend.
/// The Connect button stays enabled.
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
  // Web only (a reconnect-limited row exists there): a just-disconnected
  // device whose stack isn't ready for a reconnect yet. NOT an error —
  // linkActive signals "in flight", and the mood stays normal so the row
  // keeps the fresh-group ordering an actually-stale row would lose.
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
      // A small grey nudge in both modes: darkens the card in light mode,
      // lightens it in dark mode.
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
      showErrorSnackBar(
        ScaffoldMessenger.of(context),
        'Failed to start scan: $e',
      );
    }
  }
}

/// An inactive device row (shared by the BLE and Demo sections): a plain
/// card with a Connect button. The presentation arrives precomputed as an
/// [InactiveRowVisual] (see [inactiveRowVisual]) — the widget is purely
/// declarative over that record. The Connect button stays enabled across
/// moods (a failure hint is retryable; stale means "maybe gone", not "don't
/// try") and is disabled only while a link is busy.
class _InactiveDeviceRow extends StatelessWidget {
  const _InactiveDeviceRow({
    required this.name,
    required this.visual,
    required this.linkBusy,
    required this.onConnect,
  });

  final String name;

  /// The precomputed presentation (mood, icon, colors, subtitle).
  final InactiveRowVisual visual;

  /// Whether any link transition is in flight (disables the Connect button).
  final bool linkBusy;

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
          // Merges over the tile's title style, overriding only color.
          style: visual.titleColor == null
              ? null
              : TextStyle(color: visual.titleColor),
        ),
        // Null subtitle (web, where no RSSI reading can exist): the row
        // renders title-only rather than a permanent placeholder.
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
            // Disabled whenever a link is busy so we never issue a connect
            // against a link that is still tearing down.
            onPressed: linkBusy ? null : onConnect,
            child: const Text('Connect'),
          ),
        ),
      ),
    );
  }
}

/// The active row's Cancel/Disconnect button style. OutlinedButtons don't
/// participate in tile theming; without the explicit foreground the label
/// renders in primary on the primaryContainer surface — invisible. The
/// outline takes the row's content color (the gear/title's onPrimaryContainer)
/// so the button keeps a visible boundary on the tinted card and lines up
/// with the filled buttons' shapes; outline and label both dim while teardown
/// is in flight. The reduced horizontal padding (M3 default is 24) lets
/// "Disconnecting…" fit [deviceActionButtonWidth].
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

/// The active device row (shared by the BLE and Demo sections).
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

  /// Leading icon override (e.g. the demo device's science beaker). When
  /// null, the state-driven Bluetooth icon from [btStatusVisual] is used.
  final IconData? icon;

  /// The device model from the connect-time Device Information read (e.g.
  /// "Dynamite Sampler Pro Mk1"). Null until the read lands; the subtitle
  /// then omits it rather than showing a placeholder.
  final String? model;

  final BtLinkState linkState;

  /// Live polled RSSI for the connected device; null until first read.
  final int? connectedRssi;

  final VoidCallback onDisconnect;

  /// The gear button: jumps to the Settings tab.
  final VoidCallback onGoToSettings;

  @override
  Widget build(BuildContext context) {
    // Reuse the shared, unit-tested state → visual mapping.
    final visual = btStatusVisual(
      linkState: linkState,
      availability: BtAvailability.poweredOn, // a link is up → radio is on
      isScanning: false,
      // Never consulted: link branches return before the connectability gate.
      hasConnectableDevices: true,
      status: Theme.of(context).extension<StatusColors>()!,
      colors: Theme.of(context).colorScheme,
    );
    final scheme = Theme.of(context).colorScheme;
    final onContainer = scheme.onPrimaryContainer;
    final isConnecting = linkState == BtLinkState.connecting;
    final isDisconnecting = linkState == BtLinkState.disconnecting;

    // Compresses horizontal metrics (leading width, title gap, icon size)
    // to ensure text fits on small screens, while maintaining button alignment.
    return Card(
      color: scheme.primaryContainer,
      child: ListTile(
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
        // One flowing text, NOT a Row[Flexible(...), ...]: a Row squeezes
        // the label into whatever width the RSSI leaves (near zero on a
        // phone → one letter per line). A single Text.rich wraps at word
        // boundaries — worst case "Connected •" / "▂ -58 dBm" on two tidy
        // lines — and the WidgetSpan moves the RSSI block as a unit.
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: visual.label),
                  // The device model (DIS): null until the connect-time read
                  // lands, in which case nothing renders.
                  if (model != null) TextSpan(text: ' • $model'),
                  // Live RSSI (native only): null until the first poll lands —
                  // and forever on web — in which case nothing renders.
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Device settings',
              // Compact (48→40): part of the subtitle-lane width reclamation
              // above.
              visualDensity: VisualDensity.compact,
              onPressed: onGoToSettings,
            ),
            // Fixed width: same column/shape as the Scan and Connect buttons
            // (see [deviceActionButtonWidth]).
            SizedBox(
              width: deviceActionButtonWidth,
              child: OutlinedButton(
                style: activeRowActionButtonStyle(onContainer: onContainer),
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
            ),
          ],
        ),
      ),
    );
  }
}
