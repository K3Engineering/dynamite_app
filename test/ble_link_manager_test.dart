import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/bt_device_config.dart';
import 'package:dynamite_app/services/mockble.dart';

/// Tests for the [BleLinkManager] state machine against [MockBlePlatform],
/// driven deterministically with [fakeAsync] (same harness as
/// mockble_test.dart — no real time passes).
///
/// Mock timing: hwDelay 200 ms (availability), netDelay 1 s (connect /
/// discoverServices / calibration read). A full connect therefore takes ~3 s:
/// connect(1s) -> MTU(immediate) -> discoverServices(1s) -> calibration(1s)
/// -> subscribe. [BleLinkManager.disconnectTimeout] is 2500 ms,
/// [BleLinkManager.connectTimeout] is 5 s (the mock's slowConnect is 20 s).
///
/// IMPORTANT: every test tears its link down INSIDE the [fakeAsync] scope
/// (see [teardownLink]). A disconnect left running when the scope exits keeps
/// executing against the shared static universal_ble command queue in real
/// time, where a queued command's closure (created in a dead fake zone) never
/// completes — wedging the queue for every later test.
void main() {
  // The mock device that advertises the ADC service (see _generateServices).
  const deviceId = '2';

  setUp(() {
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.resetKnobs();
  });

  /// Builds a link manager with an [AppEvents] collector and the calibration
  /// callback wired (the app always wires it; an unwired
  /// [BleLinkManager.onCalibrationData] short-circuits the calibration read,
  /// changing setup timing). Tests that observe the feed set
  /// [BleLinkManager.onAdcData] directly.
  (BleLinkManager, List<AppEvent>) wire() {
    final events = AppEvents();
    final seen = <AppEvent>[];
    final sub = events.stream.listen(seen.add);
    addTearDown(() => unawaited(sub.cancel()));
    final link = BleLinkManager(events: events)..onCalibrationData = (_) {};
    return (link, seen);
  }

  /// In-scope link teardown: disconnect (cancelling the mock's timers) and
  /// let everything settle on the fake clock.
  void teardownLink(FakeAsync async, BleLinkManager link) {
    MockBlePlatform.instance.hangDisconnect = false;
    unawaited(link.disconnectSelectedDevice());
    async.elapse(const Duration(seconds: 4));
  }

  test('connect reaches streaming and notifications flow to onAdcData', () {
    fakeAsync((async) {
      final (link, seen) = wire();
      var received = 0;
      link.onAdcData = (_) => received++;

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(link.isStreaming, isTrue);
      expect(received, greaterThan(0));
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('a device without the ADC feed fails setup instead of "connecting"', () {
    fakeAsync((async) {
      MockBlePlatform.instance.includeAdcService = false;
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(link.isStreaming, isFalse);
      expect(link.link.state, BtLinkState.idle);
      expect(seen.whereType<BleConnectionFailed>(), hasLength(1));
      expect(seen.whereType<BleConnectionLost>(), isEmpty);
      // The GATT link came up (connect succeeded) before setup failed — it
      // must be released, not leaked.
      expect(MockBlePlatform.instance.disconnectCalls, contains(deviceId));
      expect(MockBlePlatform.instance.connectedDeviceId, isNull);

      teardownLink(async, link);
    });
  });

  test('an unexpected disconnect while streaming emits BleConnectionLost', () {
    fakeAsync((async) {
      final (link, seen) = wire();
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);

      // Simulate a remote drop: the platform reports the link down without a
      // user-requested disconnect.
      unawaited(MockBlePlatform.instance.disconnect(deviceId));
      async.elapse(const Duration(milliseconds: 100));

      expect(link.link.state, BtLinkState.idle);
      expect(seen.whereType<BleConnectionLost>(), hasLength(1));
      expect(seen.whereType<BleConnectionFailed>(), isEmpty);

      teardownLink(async, link);
    });
  });

  test(
    'a disconnect that never confirms forces idle and emits a timeout notice',
    () {
      fakeAsync((async) {
        final (link, seen) = wire();
        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));
        expect(link.isStreaming, isTrue);

        MockBlePlatform.instance.hangDisconnect = true;
        unawaited(link.disconnectSelectedDevice());
        // disconnectTimeout (2500 ms) + the availability-state query (200 ms).
        async.elapse(const Duration(seconds: 4));

        expect(link.link.state, BtLinkState.idle);
        expect(seen.whereType<BleDisconnectTimeout>(), hasLength(1));
        // A user-requested disconnect is not an unexpected drop.
        expect(seen.whereType<BleConnectionLost>(), isEmpty);

        teardownLink(async, link);
      });
    },
  );

  test('disconnecting mid post-connect setup tears down silently', () {
    fakeAsync((async) {
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      // After 1 s the GATT link is up and post-connect setup (discovery) is
      // still running: the "Setting up…" window.
      async.elapse(const Duration(seconds: 1));
      expect(link.link.state, BtLinkState.connected);

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(seconds: 4));

      expect(link.link.state, BtLinkState.idle);
      expect(link.isStreaming, isFalse);
      // The superseded setup pass bails silently: no failure or drop notices.
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('a second connect while connecting is a no-op', () {
    fakeAsync((async) {
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(link.isStreaming, isTrue);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('a failed connect attempt tears the link down and allows a retry', () {
    fakeAsync((async) {
      final (link, seen) = wire();
      MockBlePlatform.instance.failConnect = true;

      Object? error;
      unawaited(
        link.connectToDevice(deviceId).catchError((Object e) => error = e),
      );
      async.elapse(const Duration(seconds: 2));

      expect(error, isA<ConnectionException>());
      // The catch path runs the common teardown: back to idle (VM tests are
      // non-web, so no cooldown), no connection-lost notice for a link that
      // never came up.
      expect(link.link.state, BtLinkState.idle);
      expect(seen, isEmpty);

      // An immediate retry must not be blocked by leftover busy/cooldown state.
      MockBlePlatform.instance.failConnect = false;
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('cancelling a hung connect releases the link and ignores the late '
      'success', () {
    fakeAsync((async) {
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      // Mid-connect (the mock's connect takes 1 s): the attempt is in flight.
      async.elapse(const Duration(milliseconds: 500));
      expect(link.link.state, BtLinkState.connecting);

      unawaited(link.disconnectSelectedDevice());
      // The disconnect settles immediately; the mock's outstanding connect
      // completes (late) at 1 s and must be released by the guard.
      async.elapse(const Duration(seconds: 4));

      expect(link.link.state, BtLinkState.idle);
      expect(link.isStreaming, isFalse);
      expect(MockBlePlatform.instance.connectedDeviceId, isNull);
      // A user-initiated cancel surfaces no failure/lost/timeout notices…
      expect(seen, isEmpty);
      // …and exactly two platform disconnects went out: the cancel itself and
      // the guard releasing the late success. The abandoned connect future
      // resolving silently did NOT trigger a further teardown.
      expect(MockBlePlatform.instance.disconnectCalls, [deviceId, deviceId]);

      teardownLink(async, link);
    });
  });

  test('a connect failing after user cancel does not re-tear-down', () {
    fakeAsync((async) {
      MockBlePlatform.instance.failConnect = true;
      final (link, seen) = wire();

      // A cancelled attempt fails quietly: no error reaches the caller.
      Object? error;
      unawaited(
        link.connectToDevice(deviceId).catchError((Object e) => error = e),
      );
      async.elapse(const Duration(milliseconds: 500));
      expect(link.link.state, BtLinkState.connecting);

      unawaited(link.disconnectSelectedDevice());
      // The mock's connect future throws at 1 s — after the cancel teardown.
      async.elapse(const Duration(seconds: 4));

      expect(error, isNull);
      expect(link.link.state, BtLinkState.idle);
      expect(seen, isEmpty);
      // The cancel's disconnect is the only platform teardown; the late
      // failure hit the abandoned-attempt guard and returned silently.
      expect(MockBlePlatform.instance.disconnectCalls, [deviceId]);

      teardownLink(async, link);
    });
  });

  test('a connect that outlives its timeout is torn down and the late '
      'success released', () {
    fakeAsync((async) {
      MockBlePlatform.instance.slowConnect = true;
      final (link, seen) = wire();

      Object? error;
      unawaited(
        link.connectToDevice(deviceId).catchError((Object e) => error = e),
      );
      // BleLinkManager.connectTimeout (5 s) fires before the mock's 20 s
      // connect completes.
      async.elapse(const Duration(seconds: 16));

      expect(error, isNotNull);
      expect(link.link.state, BtLinkState.idle);
      expect(seen, isEmpty);
      expect(MockBlePlatform.instance.disconnectCalls, [deviceId]);

      // The platform connect completes late; the unwanted-link guard must
      // release it without adopting it.
      async.elapse(const Duration(seconds: 5));
      expect(link.link.state, BtLinkState.idle);
      expect(link.isStreaming, isFalse);
      expect(MockBlePlatform.instance.connectedDeviceId, isNull);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('a connect callback for an unknown device is released, not adopted', () {
    fakeAsync((async) {
      final (link, seen) = wire();
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);

      // A platform-level connect completes for a device the app never asked
      // for. (The mock is single-link: its disconnect of 'zzz' also severs
      // its own '2' state — only the manager's behavior is asserted here.)
      MockBlePlatform.instance.updateConnection('zzz', true);
      async.elapse(const Duration(seconds: 3));

      // The active link is untouched and the stranger's GATT link released.
      expect(link.isStreaming, isTrue);
      expect(MockBlePlatform.instance.disconnectCalls, contains('zzz'));
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('a connect callback arriving on an idle link is released, not '
      'adopted', () {
    fakeAsync((async) {
      final (link, seen) = wire();
      // Let the startup availability query resolve (hwDelay 200 ms).
      async.elapse(const Duration(milliseconds: 300));

      MockBlePlatform.instance.updateConnection(deviceId, true);
      async.elapse(const Duration(seconds: 3));

      expect(link.link.state, BtLinkState.idle);
      expect(link.isStreaming, isFalse);
      expect(MockBlePlatform.instance.disconnectCalls, contains(deviceId));
      expect(seen, isEmpty);
    });
  });

  test('notifications from foreign sources are dropped', () {
    fakeAsync((async) {
      final (link, _) = wire();
      var received = 0;
      link.onAdcData = (_) => received++;

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);
      final fromFeed = received;
      expect(fromFeed, greaterThan(0));

      // Wrong characteristic on the active device, and the ADC characteristic
      // on a foreign device: both must be dropped by _onValueChange.
      MockBlePlatform.instance.updateCharacteristicValue(
        deviceId,
        'c1234567',
        Uint8List(242),
        null,
      );
      MockBlePlatform.instance.updateCharacteristicValue(
        'zzz',
        btChrAdcFeedId,
        Uint8List(242),
        null,
      );
      async.flushMicrotasks();
      expect(received, fromFeed);

      teardownLink(async, link);
    });
  });

  test('starting a scan mid-connect does not clear the device list', () {
    fakeAsync((async) {
      final (link, _) = wire();
      // Let the startup availability query resolve (hwDelay 200 ms).
      async.elapse(const Duration(milliseconds: 300));

      unawaited(link.toggleScan());
      async.elapse(const Duration(seconds: 3));
      expect(link.devices, isNotEmpty);
      unawaited(link.toggleScan()); // stop scanning
      async.elapse(const Duration(milliseconds: 100));

      unawaited(link.connectToDevice(deviceId));
      // Mid-transition: _startScan must bail BEFORE clearing the list.
      unawaited(link.toggleScan());
      async.elapse(const Duration(milliseconds: 100));
      expect(link.devices, isNotEmpty);
      expect(link.isScanning, isFalse);

      async.elapse(const Duration(seconds: 4)); // let the connect settle
      teardownLink(async, link);
    });
  });

  test('a failing calibration read does not prevent streaming', () {
    fakeAsync((async) {
      MockBlePlatform.instance.failCalibrationRead = true;
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(link.isStreaming, isTrue);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('demo device streams and disconnects cleanly', () {
    fakeAsync((async) {
      final (link, seen) = wire();
      var received = 0;
      link.onAdcData = (_) => received++;

      unawaited(link.connectToDemoDevice());
      expect(link.isStreaming, isTrue);
      async.elapse(const Duration(milliseconds: 100));
      expect(received, greaterThan(0));

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(milliseconds: 100));
      expect(link.link.state, BtLinkState.idle);
      expect(seen, isEmpty);
    });
  });

  test('reconnecting after a clean disconnect reaches streaming again', () {
    fakeAsync((async) {
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(seconds: 4));
      expect(link.link.state, BtLinkState.idle);

      // The web reconnect-settle wait does not apply on native: an immediate
      // reconnect proceeds without delay.
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(link.isStreaming, isTrue);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('a stale disconnect callback on an idle link is a no-op', () {
    fakeAsync((async) {
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(seconds: 4));
      expect(link.link.state, BtLinkState.idle);
      expect(seen, isEmpty);

      // A late duplicate disconnect event arrives after the link is idle.
      // It must not touch state, notify, or re-stamp the settle window.
      var notifies = 0;
      link.addListener(() => notifies++);
      MockBlePlatform.instance.updateConnection(deviceId, false);
      async.flushMicrotasks();

      expect(link.link.state, BtLinkState.idle);
      expect(notifies, 0);
      expect(seen, isEmpty);
    });
  });
}
