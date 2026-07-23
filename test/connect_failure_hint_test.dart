import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/screens/devices_tab.dart' show connectFailureHint;
import 'package:dynamite_app/services/ble_link_manager.dart'
    show ConnectFailureKind;

/// Tests for [connectFailureHint], the kind -> per-row hint mapping behind the
/// Devices tab's connect-failure marker (which replaced the raw-exception
/// snackbar). The platform split is the point: on web a failed connect is
/// typically Chrome's stale device handle (the fix is a picker round-trip,
/// hence "tap Scan and pick it again"), while on native a refusal or timeout
/// can equally mean the device was grabbed by another central — the copy
/// tells the user to check that case in the same imperative voice instead
/// of implying the device is simply off or far away.
void main() {
  test('failed on web points at Scan — the actual fix for a stale handle', () {
    expect(
      connectFailureHint(ConnectFailureKind.failed, isWeb: true),
      "Couldn't connect — tap Scan and pick it again",
    );
  });

  test('failed on native asks the user to check the busy-elsewhere case', () {
    expect(
      connectFailureHint(ConnectFailureKind.failed, isWeb: false),
      "Couldn't connect — check that it's on, nearby, and not connected to another device",
    );
  });

  test('timeout asks the user to check the busy-elsewhere case on either '
      'platform', () {
    for (final isWeb in [true, false]) {
      expect(
        connectFailureHint(ConnectFailureKind.timeout, isWeb: isWeb),
        'Timed out — check that the device is on, nearby, and not connected to another device',
      );
    }
  });
}
