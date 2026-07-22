import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/screens/devices_tab.dart' show connectFailureHint;
import 'package:dynamite_app/services/ble_link_manager.dart'
    show ConnectFailureKind;

/// Tests for [connectFailureHint], the kind -> per-row hint mapping behind the
/// Devices tab's connect-failure marker (which replaced the raw-exception
/// snackbar).
void main() {
  test('failed points at Scan — the actual fix for a stale web handle', () {
    expect(
      connectFailureHint(ConnectFailureKind.failed),
      "Couldn't connect — tap Scan and pick it again",
    );
  });

  test('timeout asks for the device to be on and nearby', () {
    expect(
      connectFailureHint(ConnectFailureKind.timeout),
      'Timed out — make sure the device is on and nearby',
    );
  });
}
