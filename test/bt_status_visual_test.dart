import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/bt_scan.dart';
import 'package:dynamite_app/widgets/bt_icon.dart';
import 'package:dynamite_app/widgets/status_colors.dart';

/// Tests for the pure link and adapter/scan -> indicator mappings.
void main() {
  const status = StatusColors.light;
  final colors = ColorScheme.fromSeed(seedColor: Colors.blue);

  BtStatusVisual linkVisual(BtLinkState linkState) =>
      btActiveLinkVisual(linkState: linkState, status: status);

  BtStatusVisual adapterVisual({
    BtAvailability availability = BtAvailability.poweredOn,
    bool isScanning = false,
    bool hasConnectableDevices = false,
  }) => btAdapterScanVisual(
    availability: availability,
    isScanning: isScanning,
    hasConnectableDevices: hasConnectableDevices,
    status: status,
    colors: colors,
  );

  test('active link states map to their stage visual', () {
    for (final s in BtLinkState.values.where((s) => s != BtLinkState.idle)) {
      expect(
        linkVisual(s).showSpinner,
        s == BtLinkState.streaming ? isFalse : isTrue,
        reason: 'state $s',
      );
    }

    expect(linkVisual(BtLinkState.streaming).label, 'Connected');
    expect(linkVisual(BtLinkState.streaming).color, status.linkConnected);
    expect(linkVisual(BtLinkState.connected).label, 'Setting up…');
    expect(
      linkVisual(BtLinkState.readingConstants).label,
      'Reading board constants…',
    );
    expect(linkVisual(BtLinkState.subscribing).label, 'Starting data stream…');
    expect(linkVisual(BtLinkState.connecting).label, 'Connecting…');
    expect(linkVisual(BtLinkState.connecting).color, status.linkActive);
    expect(linkVisual(BtLinkState.disconnecting).label, 'Disconnecting…');
  });

  test('active link visual rejects idle', () {
    expect(() => linkVisual(BtLinkState.idle), throwsArgumentError);
  });

  test('scanning outranks adapter status', () {
    final v = adapterVisual(
      isScanning: true,
      availability: BtAvailability.poweredOff,
    );
    expect(v.label, contains('Scanning'));
    expect(v.color, status.linkActive);
    expect(v.showSpinner, isTrue);
  });

  test('powered-on hint requires a working Connect action', () {
    // Devices discovered and no link busy: every row is a tappable Connect,
    // so the hint is true.
    final hint = adapterVisual(hasConnectableDevices: true);
    expect(hint.label, 'Tap a device to connect');
    expect(hint.showSpinner, isFalse);

    // No connectable device — whether because the list is empty or because
    // a link is busy (the caller folds linkBusy into this flag: while
    // connected to the only discovered device, or while the demo device
    // holds the link slot, every Connect button on screen is disabled) —
    // the hint must not be emitted. An empty label: the empty block or the
    // active device row is the voice for those states.
    expect(adapterVisual(hasConnectableDevices: false).label, isEmpty);
  });

  test('adapter problems surface when not scanning', () {
    expect(
      adapterVisual(availability: BtAvailability.poweredOff).label,
      'Bluetooth is off',
    );
    expect(
      adapterVisual(availability: BtAvailability.poweredOff).color,
      colors.outline,
    );
    expect(
      adapterVisual(availability: BtAvailability.unsupported).color,
      colors.error,
    );
    expect(
      adapterVisual(availability: BtAvailability.unauthorized).color,
      colors.tertiary,
    );
    expect(
      adapterVisual(availability: BtAvailability.unknown).label,
      contains('Starting up'),
    );
    expect(
      adapterVisual(availability: BtAvailability.resetting).label,
      'Bluetooth resetting…',
    );
    expect(
      adapterVisual(availability: BtAvailability.resetting).color,
      status.linkActive,
    );
  });
}
