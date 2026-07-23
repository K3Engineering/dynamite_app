import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart'
    show AvailabilityState, BleDevice;

import '../services/ble_link_manager.dart';
import '../utils/format.dart';
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
    final scheme = Theme.of(context).colorScheme;

    // Ownership split: the top indicator speaks only for the adapter and the
    // scan (link state is forced to idle here). Per-device link state lives
    // on the device rows — the only place that scales past one device — so
    // the two never say the same thing. The one link-aware input the
    // indicator needs is whether a working Connect action exists: the "Tap a
    // device to connect" hint is withheld while any link is busy, since
    // every Connect button (inactive rows and the demo row) is disabled
    // then. This must be raw linkBusy, NOT bleLinkState: bleLinkState
    // reports idle while the demo device holds the link slot, but BLE
    // connects are refused then too.
    final visual = btStatusVisual(
      linkState: BtLinkState.idle,
      availability: bt.bluetoothState,
      isScanning: bt.isScanning,
      hasConnectableDevices: bt.devices.isNotEmpty && !bt.linkBusy,
      status: Theme.of(context).extension<StatusColors>()!,
      colors: scheme,
    );

    final isEmpty = bt.devices.isEmpty;
    // The big empty block is the empty-state voice for genuinely idle states
    // (radio off / permission / no devices found) — not during a scan.
    final showEmptyBlock = isEmpty && !bt.isScanning;

    // Resolve every BLE row's inactive presentation up front — one clock
    // reading and one staleness predicate for the whole list — then partition
    // STABLY: fresh rows keep scan order, stale ("hasn't been active for a
    // while") rows sink to the bottom, keeping scan order within each group.
    // The active row is never classed stale: its proof-of-life stamp isn't
    // refreshed while streaming, so a long-connected row would otherwise sink
    // mid-session. (Dart's List.sort isn't stable; two lists preserve order.)
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final activeId = bt.link.deviceId;
    final visuals = <String, InactiveRowVisual>{
      for (final d in bt.devices)
        d.deviceId: inactiveRowVisual(
          scanRssi: d.rssi,
          lastAliveMs: bt.lastAliveMs(d.deviceId),
          nowMs: nowMs,
          supportsScanRssi: bt.supportsScanRssi,
          failureHint: switch (bt.connectFailureFor(d.deviceId)) {
            final kind? => connectFailureHint(kind),
            null => null,
          },
          colors: scheme,
        ),
    };
    final freshRows = <BleDevice>[];
    final staleRows = <BleDevice>[];
    for (final d in bt.devices) {
      (d.deviceId != activeId &&
                  visuals[d.deviceId]!.mood == InactiveRowMood.stale
              ? staleRows
              : freshRows)
          .add(d);
    }

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Devices', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),

          // BLE devices section. The status row leads with the Bluetooth
          // status readout (adapter + scan state — never link state, which
          // belongs to the device rows) and anchors the Scan/Stop button on
          // the right, in line with the rows' trailing Connect/Disconnect
          // buttons. Always visible — Scan is reachable in every state.
          const SectionHeader('BLE devices'),
          const SizedBox(height: 8),

          // The 4px left padding mirrors the M3 Card default margin so the
          // status icon lines up with the cards below. The 28px right padding
          // is Card margin (4) + the M3 ListTile trailing content padding
          // (24 — asymmetric; the leading side is 16), so the Scan button's
          // right edge lands on the same column as the rows' trailing
          // Connect/Disconnect buttons (all share [deviceActionButtonWidth]).
          // The button is anchored right, so status text length changes never
          // move it.
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 28),
            child: Row(
              children: [
                Expanded(child: BluetoothIndicator(visual: visual)),
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

          // NOTE: the active link's row is found in the scan list (the row
          // whose id matches the link). No current path clears the list while
          // a link is up without also tearing the link down, so the active
          // row always exists — if that ever changes, the disconnect
          // affordance needs a fallback card or it disappears.
          for (final device in [...freshRows, ...staleRows])
            device.deviceId == activeId
                ? _ActiveDeviceRow(
                    name: device.name ?? 'Unknown device',
                    linkState: bt.link.state,
                    connectedRssi: bt.connectedRssi,
                    onDisconnect: bt.disconnectSelectedDevice,
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
          if (bt.link.isDemoDevice && bt.link.state != BtLinkState.idle)
            _ActiveDeviceRow(
              name: 'Demo Device',
              icon: Icons.science,
              linkState: bt.link.state,
              connectedRssi: null,
              onDisconnect: bt.disconnectSelectedDevice,
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
    );
  }

  /// The big state-aware empty block: the single empty-state voice. Title
  /// and hint are per-availability advice; icon and color come straight from
  /// the shared [btStatusVisual] mapping (this is where the failure modes
  /// live — the red "not supported" square, the permission-needed marker,
  /// "Starting up Bluetooth…"). Only the powered-on case gets its own
  /// treatment: a neutral searching icon instead of the indicator's glyph.
  Widget _buildEmptyBlock(
    BtStatusVisual visual,
    AvailabilityState availability,
  ) {
    final (title, hint) = switch (availability) {
      AvailabilityState.poweredOn => (
        'No devices found',
        'Tap Scan to search for nearby devices',
      ),
      AvailabilityState.poweredOff => (
        visual.label,
        'Turn on Bluetooth to find devices',
      ),
      AvailabilityState.unauthorized => (
        visual.label,
        'Grant Bluetooth permission to find devices',
      ),
      AvailabilityState.unsupported => (
        visual.label,
        'This device cannot use Bluetooth',
      ),
      AvailabilityState.unknown || AvailabilityState.resetting => (
        visual.label,
        'This should only take a moment',
      ),
    };
    final poweredOn = availability == AvailabilityState.poweredOn;
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

/// The inactive BLE device row's "liveness" subtitle, resolved from the
/// platform and what we know of the device:
///
///  * No liveness data at all ([lastAliveMs] null): the legacy fallbacks —
///    the RSSI line (or its transient "RSSI: --") where scan RSSI can exist,
///    no subtitle where it can't (web). The rule: no permanent placeholder
///    where no reading can exist.
///  * Fresh (age ≤ [BleLinkManager.deviceStaleAfter]): native shows the scan
///    RSSI — meaningful exactly while adverts/connection are recent. Web has
///    no scan RSSI, so it shows a "Last connected …" age instead.
///  * Stale: "Last seen …" (native) / "Last connected …" (web) with
///    `stale` set so the row de-emphasizes itself; the aged RSSI is
///    suppressed — a minutes-old reading is stale data, not information.
///
/// Ages render via [formatRelativeAge]'s coarse ladder, so the text changes
/// rarely (no distracting per-second count-up). Returns null when the
/// subtitle slot should stay empty.
({String text, bool stale})? bleRowSubtitle({
  required int? scanRssi,
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
  if (!stale && supportsScanRssi) {
    return (
      text: scanRssi != null ? 'RSSI: $scanRssi dBm' : 'RSSI: --',
      stale: false,
    );
  }
  final label = supportsScanRssi ? 'Last seen' : 'Last connected';
  return (text: '$label ${formatRelativeAge(age)}', stale: stale);
}

/// The inactive device row's presentation state, resolved by
/// [inactiveRowVisual]. Priority: a recorded connect failure outranks
/// staleness (actionable beats maybe-gone), which outranks the normal look.
/// The mood also drives the Devices tab's row ordering (stale sinks last).
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

/// Card tint for a stale device row: an onSurface-over-surface blend at this
/// alpha. The M3 container roles (e.g. surfaceContainerHighest) can't be
/// used for this — this app's M2-era ColorScheme constructors fall them back
/// to `surface`, a no-op. A small grey nudge in both modes: darkens the card
/// in light mode, lightens it in dark mode. Playground: 0.04–0.10.
const double staleCardTintAlpha = 0.06;

/// Shared width of the Devices tab's action buttons (Scan/Stop in the status
/// row, Connect on inactive rows, Cancel/Disconnect on the active row) so
/// they form one aligned column of identical shape. Sized for the longest
/// label, "Disconnecting…": ~103px at the M3 label style (14px w500, worst
/// measured across Roboto/Segoe) + the outlined button's 12px horizontal
/// padding = ~127px, with slack for font fallback differences. Tweak point:
/// 132–148.
const double deviceActionButtonWidth = 136;

/// Map platform/liveness/failure state to the inactive row's full visual.
/// Subtitle text and the staleness verdict come from [bleRowSubtitle]; this
/// layers the failure hint's priority and the per-mood colors on top.
///
/// A stale row ("hasn't been active for a while") is de-emphasized: the
/// foreground dims to the M3 disabled emphasis (onSurface at 38%) and the
/// card gets an explicit onSurface-over-surface blend at
/// [staleCardTintAlpha]. The blend is computed because the M3 container roles
/// (e.g. surfaceContainerHighest) can't be relied on here — this app's
/// M2-era ColorScheme constructors fall them back to `surface`, an invisible
/// no-op. The Connect button stays enabled AND undimmed: stale means "maybe
/// gone", not "don't try". (Tweak points: the two alphas here, the window at
/// [BleLinkManager.deviceStaleAfter].)
InactiveRowVisual inactiveRowVisual({
  required int? scanRssi,
  required int? lastAliveMs,
  required int nowMs,
  required bool supportsScanRssi,
  required String? failureHint,
  required ColorScheme colors,
}) {
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
      // A real grey nudge in both modes (darkens the card in light mode,
      // lightens it in dark mode) — see [staleCardTintAlpha].
      cardColor: Color.alphaBlend(
        colors.onSurface.withValues(alpha: staleCardTintAlpha),
        colors.surface,
      ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to start scan: $e')));
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

/// The active device row (shared by the BLE and Demo sections): a tinted
/// card carrying the live link state (spinner while connecting/setting up,
/// connected icon when streaming), the state + RSSI in the subtitle, a gear
/// shortcut to Device settings, and a state-aware Cancel/Disconnect button.
class _ActiveDeviceRow extends StatelessWidget {
  const _ActiveDeviceRow({
    required this.name,
    this.icon,
    required this.linkState,
    required this.connectedRssi,
    required this.onDisconnect,
  });

  final String name;

  /// Leading icon override (e.g. the demo device's science beaker). When
  /// null, the state-driven Bluetooth icon from [btStatusVisual] is used.
  final IconData? icon;

  /// The active link's state.
  final BtLinkState linkState;

  /// Live polled RSSI for the connected device; null until first read.
  final int? connectedRssi;

  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    // Reuse the shared, unit-tested state → visual mapping.
    final visual = btStatusVisual(
      linkState: linkState,
      availability: AvailabilityState.poweredOn, // a link is up → radio is on
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
    final isCoolingDown = linkState == BtLinkState.cooldown;

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
            // Fixed width: same column/shape as the Scan and Connect buttons
            // (see [deviceActionButtonWidth]).
            SizedBox(
              width: deviceActionButtonWidth,
              child: OutlinedButton(
                style: activeRowActionButtonStyle(onContainer: onContainer),
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
            ),
          ],
        ),
      ),
    );
  }
}
