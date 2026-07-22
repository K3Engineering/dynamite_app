import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

import 'package:dynamite_app/services/ble_link_manager.dart' show BtLinkState;
import 'package:dynamite_app/widgets/bt_icon.dart';
import 'package:dynamite_app/widgets/status_colors.dart';

/// Tests for [btStatusVisual], the pure link/adapter/scan -> indicator
/// mapping behind [BluetoothIndicator].
void main() {
  const status = StatusColors.light;
  final colors = ColorScheme.fromSeed(seedColor: Colors.blue);

  BtStatusVisual visual({
    BtLinkState linkState = BtLinkState.idle,
    AvailabilityState availability = AvailabilityState.poweredOn,
    bool isScanning = false,
    bool hasDevices = false,
  }) => btStatusVisual(
    linkState: linkState,
    availability: availability,
    isScanning: isScanning,
    hasDevices: hasDevices,
    status: status,
    colors: colors,
  );

  test('link states outrank scan and adapter status', () {
    // Even while scanning with the radio on, a link transition wins.
    final v = visual(
      linkState: BtLinkState.connecting,
      isScanning: true,
      hasDevices: true,
    );
    expect(v.label, 'Connecting…');
    expect(v.color, status.linkActive);
    expect(v.showSpinner, isTrue);
  });

  test('streaming is the only non-spinner link state', () {
    for (final s in BtLinkState.values) {
      final v = visual(linkState: s);
      expect(
        v.showSpinner,
        s == BtLinkState.idle || s == BtLinkState.streaming ? isFalse : isTrue,
        reason: 'state $s',
      );
    }
    expect(visual(linkState: BtLinkState.streaming).label, 'Connected');
    expect(visual(linkState: BtLinkState.connected).label, 'Setting up…');
    expect(
      visual(linkState: BtLinkState.disconnecting).label,
      'Disconnecting…',
    );
    expect(
      visual(linkState: BtLinkState.cooldown).label,
      'Reconnect available shortly…',
    );
  });

  test('idle + scanning outranks adapter status', () {
    final v = visual(
      isScanning: true,
      availability: AvailabilityState.poweredOff,
    );
    expect(v.label, contains('Scanning'));
    expect(v.showSpinner, isTrue);
  });

  test('idle powered-on hints reflect discovered devices', () {
    expect(visual(hasDevices: true).label, 'Tap a device to connect');
    expect(visual(hasDevices: false).label, 'Tap Scan to find devices');
  });

  test('adapter problems surface in the idle state', () {
    expect(
      visual(availability: AvailabilityState.poweredOff).label,
      'Bluetooth is off',
    );
    expect(
      visual(availability: AvailabilityState.poweredOff).color,
      colors.outline,
    );
    expect(
      visual(availability: AvailabilityState.unsupported).color,
      colors.error,
    );
    expect(
      visual(availability: AvailabilityState.unauthorized).color,
      colors.tertiary,
    );
    expect(
      visual(availability: AvailabilityState.unknown).label,
      contains('Starting up'),
    );
    expect(
      visual(availability: AvailabilityState.resetting).label,
      'Bluetooth resetting…',
    );
    expect(
      visual(availability: AvailabilityState.resetting).color,
      status.linkActive,
    );
  });
}
