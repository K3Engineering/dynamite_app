import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import '../models/bt_scan.dart' show BtAvailability, BtLinkState;
import '../status_colors.dart';

/// Everything a Bluetooth status readout displays; colors are supplied from
/// the theme.
typedef BtStatusVisual = ({
  IconData icon,
  Color color,
  String label,
  bool showSpinner,
});

/// Stage label for a non-idle link state ("Connecting…", "Disconnecting…");
/// null for [BtLinkState.idle], which has no link-side label. What each stage
/// means is documented on [BtLinkState] itself. Shared by [btActiveLinkVisual]
/// and the Live tab's status bar, so the two can't phrase the same state
/// differently.
String? btLinkStateLabel(BtLinkState state) => switch (state) {
  BtLinkState.disconnecting => 'Disconnecting…',
  BtLinkState.streaming => 'Connected',
  BtLinkState.connected => 'Setting up…',
  BtLinkState.readingConstants => 'Reading board constants…',
  BtLinkState.subscribing => 'Starting data stream…',
  BtLinkState.maintenance => 'Maintenance mode',
  BtLinkState.connecting => 'Connecting…',
  BtLinkState.idle => null,
};

/// Map an active link state to its active-row visual.
///
/// Throws [ArgumentError] for [BtLinkState.idle]: active rows must not
/// represent an absent link.
BtStatusVisual btActiveLinkVisual({
  required BtLinkState linkState,
  required StatusColors status,
}) {
  final label = btLinkStateLabel(linkState);
  if (label == null) {
    throw ArgumentError.value(
      linkState,
      'linkState',
      'must represent an active link',
    );
  }

  final streaming = linkState == BtLinkState.streaming;
  final maintenance = linkState == BtLinkState.maintenance;
  return (
    icon: streaming
        ? Icons.bluetooth_connected
        : maintenance
        ? Icons.build_circle_outlined
        : Icons.bluetooth_searching,
    color: streaming ? status.linkConnected : status.linkActive,
    label: label,
    showSpinner: !streaming && !maintenance,
  );
}

/// Map adapter/scan state to the Devices tab top indicator visual. Scan state
/// outranks adapter status. Link-state presentation lives in
/// [btActiveLinkVisual].
///
/// [hasConnectableDevices] is the caller-resolved truth condition for the
/// "Tap a device to connect" hint: devices are discovered AND no link is
/// busy. A busy link — including the demo device, which occupies the single
/// link slot and so gets BLE connects refused — disables every Connect
/// button on screen, so the hint must not be emitted then.
BtStatusVisual btAdapterScanVisual({
  required BtAvailability availability,
  required bool isScanning,
  required bool hasConnectableDevices,
  required StatusColors status,
  required ColorScheme colors,
}) {
  final active = status.linkActive;
  final connected = status.linkConnected;

  (IconData, Color, String) resolve() {
    if (isScanning) {
      // On web the device list lives in the browser's own picker popup, not
      // in our list, so we tell the user to choose there.
      return (
        Icons.bluetooth_searching,
        active,
        kIsWeb ? 'Choose a device…' : 'Scanning for devices…',
      );
    }
    switch (availability) {
      case BtAvailability.poweredOn:
        // A previously-discovered device can remain connectable after a scan
        // stops, so surface that rather than implying a scan is required —
        // but only while a Connect action actually exists (see
        // [hasConnectableDevices]): while a link is busy every Connect
        // button is disabled and the active device row shows the state.
        if (hasConnectableDevices) {
          return (Icons.bluetooth, connected, 'Tap a device to connect');
        }
        // Otherwise an empty label: with nothing found, the Devices tab's
        // empty block already carries the "no devices, tap Scan" guidance;
        // with a link busy, the active row does. The indicator renders
        // icon-only for an empty label.
        return (Icons.bluetooth, connected, '');
      case BtAvailability.poweredOff:
        return (Icons.bluetooth_disabled, colors.outline, 'Bluetooth is off');
      case BtAvailability.unknown:
        return (Icons.question_mark, colors.outline, 'Starting up Bluetooth…');
      case BtAvailability.resetting:
        return (Icons.question_mark, active, 'Bluetooth resetting…');
      case BtAvailability.unsupported:
        return (Icons.stop, colors.error, 'Bluetooth not supported');
      case BtAvailability.unauthorized:
        return (Icons.stop, colors.tertiary, 'Bluetooth permission needed');
    }
  }

  final (icon, color, label) = resolve();
  return (icon: icon, color: color, label: label, showSpinner: isScanning);
}

/// The Devices tab top indicator's presentation mode, resolved by
/// [topIndicatorMode]. The indicator draws an icon only when the glyph
/// carries information the device rows don't — scan progress or an adapter
/// failure — and stays text-only or hidden in powered-on nominal states,
/// where a static Bluetooth glyph would read as a stale link-state icon
/// next to the rows' stateful ones.
enum TopIndicatorMode {
  /// Nothing renders: the tab's empty block is on screen and already shows
  /// the state (icon included).
  quiet,

  /// Label only, no icon: powered-on nominal states ("Tap a device to
  /// connect"). An empty label renders nothing at all (e.g. a link is
  /// busy — the active device row shows the state then).
  textOnly,

  /// Icon (with spinner while in flight) plus label: scanning, or an
  /// adapter failure the empty block isn't covering.
  iconAndLabel,
}

/// Resolve the top indicator's presentation mode from adapter/scan state
/// and whether the tab's empty block is on screen. Whenever the empty block
/// shows, the indicator goes quiet — its icon and label would duplicate the
/// block's. Adapter failures normally imply an empty device list (no scan
/// is possible, and poweredOff clears the list), so their icon + label only
/// survive the dedupe in the rare case of a stale populated list (e.g.
/// permission revoked mid-session).
TopIndicatorMode topIndicatorMode({
  required BtAvailability availability,
  required bool isScanning,
  required bool emptyBlockVisible,
}) {
  // The empty block can only show while not scanning, so this can't
  // suppress the scan progress below.
  if (emptyBlockVisible) return TopIndicatorMode.quiet;
  if (isScanning) return TopIndicatorMode.iconAndLabel;
  // Adapter failures: distinct glyphs (off / permission / unsupported /
  // startup).
  if (availability != BtAvailability.poweredOn) {
    return TopIndicatorMode.iconAndLabel;
  }
  return TopIndicatorMode.textOnly;
}

/// Compact Bluetooth status readout for the Devices tab's status row.
class BluetoothIndicator extends StatelessWidget {
  final BtStatusVisual visual;

  /// How much of [visual] to draw (see [topIndicatorMode]).
  final TopIndicatorMode mode;

  const BluetoothIndicator({
    super.key,
    required this.visual,
    required this.mode,
  });

  @override
  Widget build(BuildContext context) {
    if (mode == TopIndicatorMode.quiet) {
      return const SizedBox.shrink();
    }
    const double size = 32;
    final label = visual.label;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mode == TopIndicatorMode.iconAndLabel) ...[
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(visual.icon, size: size, color: visual.color),
              if (visual.showSpinner)
                const SizedBox(
                  height: size,
                  width: size,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (label.isNotEmpty) const SizedBox(width: 8),
        ],
        if (label.isNotEmpty)
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
