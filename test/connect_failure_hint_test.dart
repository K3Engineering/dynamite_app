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
/// names that case instead of implying the device is off or far away.
void main() {
  test('failed on web points at Scan — the actual fix for a stale handle', () {
    expect(
      connectFailureHint(ConnectFailureKind.failed, isWeb: true),
      "Couldn't connect — tap Scan and pick it again",
    );
  });

  test('failed on native names the busy-elsewhere case', () {
    expect(
      connectFailureHint(ConnectFailureKind.failed, isWeb: false),
      "Couldn't connect — it may be off, out of range, or connected to another device",
    );
  });

  test('timeout names the busy-elsewhere case on either platform', () {
    for (final isWeb in [true, false]) {
      expect(
        connectFailureHint(ConnectFailureKind.timeout, isWeb: isWeb),
        'Timed out — it may be off, out of range, or connected to another device',
      );
    }
  });
}
