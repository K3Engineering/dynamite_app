import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/bt_device_config.dart';
import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/bt_scan.dart';
import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/services/demo_device.dart';
import 'package:dynamite_app/services/kvs_protocol.dart';
import 'helpers/flash_docs.dart';
import 'package:dynamite_app/services/mockble.dart';
import 'package:dynamite_app/services/ota_client.dart';

/// Tests for the [BleLinkManager] state machine against [MockBlePlatform],
/// driven deterministically with [fakeAsync] (same harness as
/// mockble_test.dart — no real time passes).
///
/// Mock timing: hwDelay 200 ms (availability), netDelay 1 s (connect /
/// discoverServices). KVS commands (subscription, flash read), the ADC
/// config read and the DIS identity reads answer synchronously, so a full
/// connect takes ~2 s: connect(1s) -> MTU (immediate) -> discoverServices(1s)
/// -> DIS reads (instant) -> ADC config + KVS (instant) -> feed subscribe.
/// The link shows [BtLinkState.connected] ("Setting up…")
/// through discovery, [BtLinkState.readingConstants] ("Reading board
/// constants…") from discovery's end until the flash read completes, and
/// [BtLinkState.subscribing] ("Starting data stream…") for the feed
/// subscription. [BleLinkManager.disconnectTimeout]
/// is 2500 ms, [BleLinkManager.connectTimeout] is 5 s (the mock's
/// slowConnect is 20 s).
///
/// IMPORTANT: every test tears its link down INSIDE the [fakeAsync] scope
/// (see [teardownLink]). A disconnect left running when the scope exits keeps
/// executing against the shared static universal_ble command queue in real
/// time, where a queued command's closure (created in a dead fake zone) never
/// completes — wedging the queue for every later test.
void main() {
  /// The fixture rig's slot keys with cap replaced — the complete set a
  /// save submits (writeSlots owns every lc key; a partial map would
  /// delete the others).
  Map<String, String> slotsWith({required String cap}) => flashFromDoc(
    demoBoardCalibrationDoc,
    pgaGains: const [1, 1, 1, 1],
  ).slots.toKv()..['lc0.cap'] = cap;

  // The mock device that advertises the ADC service (see _generateServices).
  const deviceId = '2';

  setUp(() {
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.resetKnobs();
  });

  /// Builds a link manager with an [AppEvents] collector and the flash
  /// callback wired (the app always wires it; tests that observe the feed set
  /// [BleLinkManager.onAdcData] directly). [onDeviceFlash] defaults to a
  /// no-op; tests that inspect the delivered flash pass their own.
  (BleLinkManager, List<AppEvent>) wire({
    void Function(DeviceFlash flash)? onDeviceFlash,
    void Function(Uint8List data)? onAdcData,
    void Function(int sampleRateHz)? onSampleRate,
  }) {
    final events = AppEvents();
    final seen = <AppEvent>[];
    final sub = events.stream.listen(seen.add);
    addTearDown(() => unawaited(sub.cancel()));
    final link = BleLinkManager(
      events: events,
      demo: DemoDevice(),
      onDeviceFlash: onDeviceFlash ?? (_) {},
      onAdcData: onAdcData ?? (_) {},
      onSampleRate: onSampleRate ?? (_) {},
    );
    return (link, seen);
  }

  /// In-scope link teardown: disconnect (cancelling the mock's timers) and
  /// let everything settle on the fake clock.
  void teardownLink(FakeAsync async, BleLinkManager link) {
    MockBlePlatform.instance.hangDisconnect = false;
    unawaited(link.disconnectSelectedDevice());
    async.elapse(const Duration(seconds: 4));
  }

  /// Let the constructor's startup work drain through the shared static
  /// command queue: setting [UniversalBle.onAvailabilityChange] makes
  /// universal_ble issue its own availability query AND the manager issues
  /// another ([BleLinkManager._updateBluetoothState]) — two 200 ms mock
  /// round-trips, serialised, so the second lands at ~400 ms. A test that
  /// exits its [fakeAsync] scope with that command still pending wedges the
  /// queue for every later test (the pending timer belongs to the dead fake
  /// zone and never fires). Tests that don't otherwise elapse past ~400 ms
  /// must run this before exiting. (The manager's own [AvailabilityState]
  /// still resolves at ~200 ms — the setter's callback sets it — which is
  /// why this wedge is invisible in the wedging test itself.)
  void settleStartup(FakeAsync async) =>
      async.elapse(const Duration(milliseconds: 500));

  test('connect reaches streaming and notifications flow to onAdcData', () {
    fakeAsync((async) {
      var received = 0;
      final (link, seen) = wire(onAdcData: (_) => received++);

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(link.isStreaming, isTrue);
      expect(received, greaterThan(0));
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('connect reads the device identity; teardown clears it', () {
    fakeAsync((async) {
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(link.isStreaming, isTrue);
      // The values come from MockBlePlatform's DIS table. The serial is
      // non-null here because VM tests are non-web (web blocklists 0x2A25).
      final info = link.connectedDeviceInfo;
      expect(info, isNotNull);
      expect(info!.manufacturer, 'K3 Engineering');
      expect(info.model, 'Dynamite Sampler Pro Mk1');
      expect(info.serial, 'A4CF1208F51E');
      expect(info.hardwareRev, 'v700P');
      expect(info.firmwareRev, 'v700P|mock-1.0.0');
      expect(link.negotiatedMtu, 247);
      expect(link.minAdcPacketBytes, 242);
      expect(link.maxAdcPacketBytes, 242);
      expect(seen, isEmpty);

      MockBlePlatform.instance.updateCharacteristicValue(
        deviceId,
        btChrAdcFeedId,
        Uint8List(20),
        null,
      );
      async.flushMicrotasks();
      expect(link.minAdcPacketBytes, 20);
      expect(link.maxAdcPacketBytes, 242);

      teardownLink(async, link);
      expect(link.connectedDeviceInfo, isNull);
      expect(link.negotiatedMtu, isNull);
      expect(link.minAdcPacketBytes, isNull);
      expect(link.maxAdcPacketBytes, isNull);
    });
  });

  test('a device without the ADC feed fails setup instead of "connecting"', () {
    fakeAsync((async) {
      MockBlePlatform.instance.includeAdcService = false;
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(link.isStreaming, isFalse);
      expect(link.linkState, BtLinkState.idle);
      expect(seen.whereType<BleConnectionFailed>(), hasLength(1));
      expect(seen.whereType<BleConnectionLost>(), isEmpty);
      // The GATT link came up (connect succeeded) before setup failed — it
      // must be released, not leaked.
      expect(MockBlePlatform.instance.disconnectCalls, contains(deviceId));
      expect(MockBlePlatform.instance.connectedDeviceId, isNull);

      teardownLink(async, link);
    });
  });

  test('an unreadable ADC config fails setup instead of "connecting"', () {
    fakeAsync((async) {
      MockBlePlatform.instance.badAdcConfig = true;
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(link.isStreaming, isFalse);
      expect(link.linkState, BtLinkState.idle);
      expect(seen.whereType<BleConnectionFailed>(), hasLength(1));
      expect(seen.whereType<BleConnectionLost>(), isEmpty);
      expect(MockBlePlatform.instance.disconnectCalls, contains(deviceId));

      teardownLink(async, link);
    });
  });

  test('connect pushes the parsed sample rate before streaming (GATT and '
      'demo)', () {
    fakeAsync((async) {
      final rates = <int>[];
      final (link, _) = wire(onSampleRate: rates.add);

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);
      expect(rates, [1000]);
      teardownLink(async, link);

      unawaited(link.connectToDemoDevice());
      async.elapse(const Duration(seconds: 1));
      expect(rates, [1000, 1000]);
      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(milliseconds: 100));
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

      expect(link.linkState, BtLinkState.idle);
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

        expect(link.linkState, BtLinkState.idle);
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
      expect(link.linkState, BtLinkState.connected);

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(seconds: 4));

      expect(link.linkState, BtLinkState.idle);
      expect(link.isStreaming, isFalse);
      // The superseded setup pass bails silently: no failure or drop notices.
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('disconnecting mid stream-start tears down silently', () {
    fakeAsync((async) {
      // Hold the "Reading board constants…" window open: the connect-time
      // KVS flash read takes ~1s per command.
      MockBlePlatform.instance.kvsCommandDelay = const Duration(seconds: 1);
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      // After 2.5 s the GATT link is up, discovery is done, and the KVS
      // flash read is still running: the "Reading board constants…" window.
      async.elapse(const Duration(milliseconds: 2500));
      expect(link.linkState, BtLinkState.readingConstants);

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(seconds: 4));

      expect(link.linkState, BtLinkState.idle);
      expect(link.isStreaming, isFalse);
      // The superseded setup pass bails silently: no failure or drop
      // notices — in particular no spurious "calibration unreadable" from
      // the aborted KVS read.
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
      // non-web, so no reconnect embargo), no connection-lost notice for a link that
      // never came up.
      expect(link.linkState, BtLinkState.idle);
      expect(seen, isEmpty);

      // An immediate retry must not be blocked by leftover busy/embargo state.
      MockBlePlatform.instance.failConnect = false;
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('a failed connect records a per-row failure marker that a retry '
      'clears', () {
    fakeAsync((async) {
      final (link, seen) = wire();
      MockBlePlatform.instance.failConnect = true;

      Object? error;
      unawaited(
        link.connectToDevice(deviceId).catchError((Object e) => error = e),
      );
      async.elapse(const Duration(seconds: 2));

      expect(error, isA<ConnectionException>());
      // The row marker is the user-facing channel for the failure (no toast).
      expect(
        (link.outcomeFor(deviceId) as ConnectRefused).kind,
        ConnectFailureKind.failed,
      );
      expect(link.linkState, BtLinkState.idle);
      expect(seen, isEmpty);

      // A new attempt supersedes the marker immediately (before it succeeds).
      MockBlePlatform.instance.failConnect = false;
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(milliseconds: 100));
      expect(link.outcomeFor(deviceId), isNull);

      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('a timed-out connect records a timeout failure marker', () {
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

      expect(error, isA<TimeoutException>());
      expect(
        (link.outcomeFor(deviceId) as ConnectRefused).kind,
        ConnectFailureKind.timeout,
      );
      expect(link.linkState, BtLinkState.idle);
      expect(seen, isEmpty);

      // The platform connect completes late; the unwanted-link guard must
      // release it without adopting it.
      async.elapse(const Duration(seconds: 5));
      expect(link.isStreaming, isFalse);
      expect(MockBlePlatform.instance.connectedDeviceId, isNull);

      teardownLink(async, link);
    });
  });

  test('a connect refused via the callback (native flavor) records a failure '
      'marker and skips the reconnect embargo', () {
    fakeAsync((async) {
      final (link, seen) = wire();
      MockBlePlatform.instance.failConnectViaCallback = true;

      // Native stacks report a refused connect through the connection-change
      // callback, which universal_ble delivers to the manager BEFORE it
      // errors the connect() future (from the same event). The marker is
      // recorded on the callback path, so the caller's future completes
      // silently — the per-row marker is the single user-facing channel.
      Object? error;
      unawaited(
        link.connectToDevice(deviceId).catchError((Object e) => error = e),
      );
      async.elapse(const Duration(seconds: 2));

      expect(error, isNull);
      expect(
        (link.outcomeFor(deviceId) as ConnectRefused).kind,
        ConnectFailureKind.failed,
      );
      // Back to idle (VM tests are non-web, so no reconnect embargo either way) with
      // no notices and no GATT release: the platform reported the link down.
      expect(link.linkState, BtLinkState.idle);
      expect(seen, isEmpty);
      expect(MockBlePlatform.instance.disconnectCalls, isEmpty);

      // An immediate retry must not be blocked by leftover state.
      MockBlePlatform.instance.failConnectViaCallback = false;
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('a duplicate connect event while streaming is ignored', () {
    fakeAsync((async) {
      final (link, seen) = wire();
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);

      // A spurious duplicate "connected" event for the active device must
      // not regress the state or re-run post-connect setup.
      MockBlePlatform.instance.updateConnection(deviceId, true);
      async.flushMicrotasks();

      expect(link.linkState, BtLinkState.streaming);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('no RSSI polling runs against the demo device', () {
    fakeAsync((async) {
      final (link, _) = wire();
      settleStartup(async);

      unawaited(link.connectToDemoDevice());
      // Polling follows the streaming lifetime directly (no tab-visibility
      // gate); the demo device has no real radio, so it must stay exempt.
      async.elapse(const Duration(seconds: 5));

      expect(MockBlePlatform.instance.readRssiCalls, 0);
      expect(link.negotiatedMtu, isNull);
      expect(link.minAdcPacketBytes, 242);
      expect(link.maxAdcPacketBytes, 242);

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(milliseconds: 100));
    });
  });

  test('RSSI polling runs for the streaming lifetime, not gated on tab '
      'visibility', () {
    fakeAsync((async) {
      final (link, _) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);

      // No setDevicesTabVisible call: polling is tied to the streaming
      // lifetime, not to whether an RSSI-showing tab is on screen.
      async.elapse(BleLinkManager.rssiPollInterval * 3);

      expect(MockBlePlatform.instance.readRssiCalls, greaterThanOrEqualTo(3));
      expect(link.connectedRssi, 1); // the mock's fixed reading

      // The poller dies with the link.
      teardownLink(async, link);
      final callsAtTeardown = MockBlePlatform.instance.readRssiCalls;
      async.elapse(BleLinkManager.rssiPollInterval * 3);
      expect(MockBlePlatform.instance.readRssiCalls, callsAtTeardown);
    });
  });

  test('cancelling a hung connect releases the link and ignores the late '
      'success', () {
    fakeAsync((async) {
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      // Mid-connect (the mock's connect takes 1 s): the attempt is in flight.
      async.elapse(const Duration(milliseconds: 500));
      expect(link.linkState, BtLinkState.connecting);

      unawaited(link.disconnectSelectedDevice());
      // The disconnect settles immediately; the mock's outstanding connect
      // completes (late) at 1 s and must be released by the guard.
      async.elapse(const Duration(seconds: 4));

      expect(link.linkState, BtLinkState.idle);
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
      expect(link.linkState, BtLinkState.connecting);

      unawaited(link.disconnectSelectedDevice());
      // The mock's connect future throws at 1 s — after the cancel teardown.
      async.elapse(const Duration(seconds: 4));

      expect(error, isNull);
      expect(link.linkState, BtLinkState.idle);
      expect(seen, isEmpty);
      // A cancelled attempt records no per-row failure marker either.
      expect(link.outcomeFor(deviceId), isNull);
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
      expect(link.linkState, BtLinkState.idle);
      expect(seen, isEmpty);
      expect(MockBlePlatform.instance.disconnectCalls, [deviceId]);

      // The platform connect completes late; the unwanted-link guard must
      // release it without adopting it.
      async.elapse(const Duration(seconds: 5));
      expect(link.linkState, BtLinkState.idle);
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

      expect(link.linkState, BtLinkState.idle);
      expect(link.isStreaming, isFalse);
      expect(MockBlePlatform.instance.disconnectCalls, contains(deviceId));
      expect(seen, isEmpty);
    });
  });

  test('notifications from foreign sources are dropped', () {
    fakeAsync((async) {
      var received = 0;
      final (link, _) = wire(onAdcData: (_) => received++);

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);
      final fromFeed = received;
      expect(fromFeed, greaterThan(0));
      expect(link.minAdcPacketBytes, 242);
      expect(link.maxAdcPacketBytes, 242);

      // Wrong characteristic on the active device, and the ADC characteristic
      // on a foreign device: both must be dropped by _onValueChange.
      MockBlePlatform.instance.updateCharacteristicValue(
        deviceId,
        'c1234567',
        Uint8List(10),
        null,
      );
      MockBlePlatform.instance.updateCharacteristicValue(
        'zzz',
        btChrAdcFeedId,
        Uint8List(10),
        null,
      );
      async.flushMicrotasks();
      expect(received, fromFeed);
      expect(link.minAdcPacketBytes, 242);

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

  test(
    'a failing scan start rolls back state and restores the device list',
    () {
      fakeAsync((async) {
        final (link, _) = wire();
        // Let the startup availability query resolve (hwDelay 200 ms).
        async.elapse(const Duration(milliseconds: 300));

        // Discover a device with a first scan, then stop.
        unawaited(link.toggleScan());
        async.elapse(const Duration(seconds: 3));
        expect(link.devices, isNotEmpty);
        unawaited(link.toggleScan());
        async.elapse(const Duration(milliseconds: 100));
        final discovered = link.devices.map((d) => d.deviceId).toList();

        // A refused scan start surfaces the error to the caller, leaves
        // scanning off, and restores the previously-discovered list (a
        // failed/cancelled scan changes nothing).
        MockBlePlatform.instance.failScan = true;
        Object? caught;
        unawaited(
          link.toggleScan().catchError((Object e) {
            caught = e;
          }),
        );
        async.elapse(const Duration(milliseconds: 100));
        expect(caught, isA<StateError>());
        expect(link.isScanning, isFalse);
        expect(link.devices.map((d) => d.deviceId).toList(), discovered);
      });
    },
  );

  test('scan tap with the radio off requests permissions and enables it', () {
    fakeAsync((async) {
      MockBlePlatform.instance.isEnabled = false;
      final (link, _) = wire();
      settleStartup(async);
      expect(link.bluetoothState, BtAvailability.poweredOff);

      unawaited(link.toggleScan());
      async.elapse(const Duration(seconds: 1));

      expect(MockBlePlatform.instance.requestPermissionsCalls, 1);
      expect(link.bluetoothState, BtAvailability.poweredOn);
      expect(link.isScanning, isTrue);

      unawaited(link.toggleScan()); // stop scanning
      async.elapse(const Duration(milliseconds: 100));
    });
  });

  test('scan tap with a dismissed enable dialog does not scan', () {
    fakeAsync((async) {
      MockBlePlatform.instance.isEnabled = false;
      MockBlePlatform.instance.refuseEnable = true;
      final (link, _) = wire();
      settleStartup(async);

      unawaited(link.toggleScan());
      async.elapse(const Duration(seconds: 1));

      expect(MockBlePlatform.instance.requestPermissionsCalls, 1);
      expect(link.bluetoothState, BtAvailability.poweredOff);
      expect(link.isScanning, isFalse);
    });
  });

  group('isWebPickerDismissal', () {
    test('matches the flutter_web_bluetooth picker-dismissal error names', () {
      expect(
        isWebPickerDismissal(
          'UserCancelledDialogError: User cancelled the requestDevice() chooser.',
        ),
        isTrue,
      );
      expect(
        isWebPickerDismissal('DeviceNotFoundError: No devices found.'),
        isTrue,
      );
    });

    test('matches Bluefy picker cancels (BrowserError), but not '
        'SecurityError', () {
      // Bluefy (iOS Web Bluetooth) rejects a cancelled requestDevice() with
      // its own code, which flutter_web_bluetooth wraps in a BrowserError.
      expect(isWebPickerDismissal('BrowserError: 2'), isTrue);
      // A BrowserError wrapping a SecurityError (permissions-policy denial)
      // is a genuine failure, not a cancel.
      expect(isWebPickerDismissal('BrowserError: SecurityError: x'), isFalse);
    });

    test('rejects genuine failures', () {
      expect(isWebPickerDismissal(StateError('Mock scan failure')), isFalse);
      expect(
        isWebPickerDismissal(
          'WebBluetoothGloballyDisabled: api globally disabled',
        ),
        isFalse,
      );
      expect(isWebPickerDismissal('BrowserError: SecurityError: x'), isFalse);
    });
  });

  test('a failing KVS channel fails the connection', () {
    fakeAsync((async) {
      MockBlePlatform.instance.failKvsCommands = true;
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      // A link whose KVS channel can't come up can't save rig slots or the
      // device name — streaming on without it would be a half-usable link,
      // so the connect fails (same verdict as an unreadable ADC config or
      // a missing ADC feed).
      expect(link.isStreaming, isFalse);
      expect(seen, [isA<BleConnectionFailed>()]);
      // The exact reason is recorded for the Devices-tab row (the toast stays
      // generic); a torn-down setup is a disconnect.
      expect(link.outcomeFor(deviceId), isA<SetupFailed>());

      teardownLink(async, link);
    });
  });

  test('an unprovisioned board (empty KVS) connects and streams', () {
    fakeAsync((async) {
      final mock = MockBlePlatform.instance;
      mock.seedKvs(kvsFromDoc(''));
      KvsSnapshot? servedSnapshot;
      final (link, seen) = wire(
        onDeviceFlash: (flash) => servedSnapshot = flash.kvs,
      );

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      // An EMPTY KVS is a working channel with no data, not a failure: the
      // connect succeeds and the flash read serves an empty store —
      // the unprovisioned mode, raw counts only (dev boards stay usable).
      expect(link.isStreaming, isTrue);
      expect(servedSnapshot!.factory, isEmpty);
      expect(servedSnapshot!.user, isEmpty);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('invalid known flash streams raw with an invalid board', () {
    fakeAsync((async) {
      MockBlePlatform.instance.seedKvs(
        kvsFromDoc('adc_fsr=1.2\nexc=soon\nafe_gain=101\ncharging=enabled'),
      );
      DeviceFlash? delivered;
      final (link, seen) = wire(onDeviceFlash: (flash) => delivered = flash);

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      // A board the app can't fully make sense of streams raw counts with an
      // invalid-board marker instead of failing the connection or parking the
      // link: the ADC feed is subscribed, the flash callback fires, and the
      // board carries the parser's reason for the UI warning.
      expect(link.isStreaming, isTrue);
      expect(delivered, isNotNull);
      final board = delivered!.board;
      expect(board, isA<InvalidBoardCalibration>());
      expect((board as InvalidBoardCalibration).detail, contains('bad exc'));
      expect(MockBlePlatform.instance.gattOpLog, contains('adc:sub'));
      // Not a setup failure: the connection succeeded, so no row hint.
      expect(link.outcomeFor(deviceId), isNull);
      expect(seen.whereType<BleConnectionFailed>(), isEmpty);

      // A repaired device re-reads as a provisioned board.
      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(seconds: 4));
      expect(link.linkState, BtLinkState.idle);

      MockBlePlatform.instance.resetKnobs();
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.linkState, BtLinkState.streaming);
      expect(delivered!.board, isA<ProvisionedBoardCalibration>());
      expect(seen.whereType<BleConnectionFailed>(), isEmpty);
      teardownLink(async, link);
    });
  });

  test('a mid-session flash write pauses and resumes the ADC feed', () {
    fakeAsync((async) {
      // With the firmware lock emulated, KVS commands only succeed while
      // the feed is NOT subscribed (busy answers otherwise) — so a
      // successful write proves the link manager unsubscribed around it.
      MockBlePlatform.instance.kvsLockWhenStreaming = true;
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);

      Object? error;
      unawaited(
        link.backend!
            .writeSlots(slotsWith(cap: '250'))
            .then((_) {}, onError: (Object e) => error = e),
      );
      async.elapse(const Duration(seconds: 1));

      expect(error, isNull);
      expect(
        MockBlePlatform.instance.kvsStore[kvsFolderUser]!['lc0.cap'],
        '250',
      );
      // The feed resumed after the write.
      expect(link.isStreaming, isTrue);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('concurrent flash write and name store run as serialized feed '
      'pauses', () {
    fakeAsync((async) {
      // The firmware lock emulated + slow KVS answers: without envelope
      // serialization, the write's resubscribe lands while the rename's
      // command is still in flight and the lock answers busy. The
      // command delay is set only once streaming so the connect-time flash
      // read (~70 KVS round-trips) stays fast.
      MockBlePlatform.instance.kvsLockWhenStreaming = true;
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);
      MockBlePlatform.instance.kvsCommandDelay = const Duration(
        milliseconds: 200,
      );
      MockBlePlatform.instance.gattOpLog.clear();

      Object? writeError;
      Object? nameError;
      unawaited(
        link.backend!
            .writeSlots(slotsWith(cap: '250'))
            .then((_) {}, onError: (Object e) => writeError = e),
      );
      unawaited(
        link
            .setDeviceName('Rig 7')
            .then((_) {}, onError: (Object e) => nameError = e),
      );
      async.elapse(const Duration(seconds: 5));

      expect(writeError, isNull);
      expect(nameError, isNull);
      expect(
        MockBlePlatform.instance.kvsStore[kvsFolderUser]!['lc0.cap'],
        '250',
      );
      expect(
        MockBlePlatform.instance.kvsStore[kvsFolderSettings]![kvsKeyDeviceName],
        'Rig 7',
      );
      expect(link.isStreaming, isTrue);
      expect(seen, isEmpty);
      // The envelopes ran back to back, not interleaved: each op's KVS
      // command is bracketed by ITS unsubscribe/subscribe pair.
      expect(MockBlePlatform.instance.gattOpLog, [
        'adc:unsub',
        'kvs:SET${kvsFolderUser}lc0.cap=250',
        'adc:sub',
        'adc:unsub',
        'kvs:SET$kvsFolderSettings$kvsKeyDeviceName=Rig 7',
        'adc:sub',
      ]);

      teardownLink(async, link);
    });
  });

  test('a failed feed resume after a flash write tears the link down', () {
    fakeAsync((async) {
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);

      MockBlePlatform.instance.failFeedSubscribe = true;
      Object? error;
      unawaited(
        link.backend!
            .writeSlots(slotsWith(cap: '250'))
            .then((_) {}, onError: (Object e) => error = e),
      );
      async.elapse(const Duration(seconds: 1));

      // The write propagated the resume failure, and the link is gone:
      // marked streaming with a dead feed forever is not an option.
      expect(error, isA<StateError>());
      expect(link.isStreaming, isFalse);
      expect(link.linkState, BtLinkState.idle);
      expect(seen, [isA<BleConnectionLost>()]);
      // The platform link was still up, so teardown released the GATT side.
      expect(MockBlePlatform.instance.disconnectCalls, [deviceId]);
      // The link is connectable again immediately (native: no reconnect embargo).
      expect(link.linkBusy, isFalse);
    });
  });

  test('a completed flash ends the link: no feed resume, no lost notice', () {
    fakeAsync((async) {
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);

      MockBlePlatform.instance.gattOpLog.clear();
      Object? error;
      // 600 B: two full 244-byte chunks plus a 112-byte tail.
      unawaited(
        link
            .runOta((client) => client.flash(image: Uint8List(600)))
            .then((_) {}, onError: (Object e) => error = e),
      );
      async.elapse(const Duration(seconds: 4));

      expect(error, isNull);
      expect(MockBlePlatform.instance.otaDataBytes, 600);
      // An accepted image reboots the device, so the session ends the link
      // on its own initiative rather than resuming the feed into the dying
      // radio: the pause unwound without a resubscribe, the platform side
      // was released, and no connection-lost notice fired.
      expect(link.linkState, BtLinkState.idle);
      expect(MockBlePlatform.instance.gattOpLog, ['adc:unsub']);
      expect(MockBlePlatform.instance.disconnectCalls, [deviceId]);
      expect(seen, isEmpty);
      expect(link.linkBusy, isFalse);
    });
  });

  test('a refused flash keeps the link and resumes the feed', () {
    fakeAsync((async) {
      MockBlePlatform.instance.refuseOtaStart = true;
      final (link, seen) = wire();

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);

      MockBlePlatform.instance.gattOpLog.clear();
      Object? error;
      unawaited(
        link
            .runOta((client) => client.flash(image: Uint8List(600)))
            .then((_) {}, onError: (Object e) => error = e),
      );
      async.elapse(const Duration(seconds: 4));

      // Nothing rebooted, so the flash error surfaces and the session's
      // feed pause resumes as usual — the link stays up.
      expect(error, isA<OtaFlashException>());
      expect('$error', contains('declined to start'));
      expect(MockBlePlatform.instance.otaDataBytes, 0);
      expect(MockBlePlatform.instance.gattOpLog, ['adc:unsub', 'adc:sub']);
      expect(link.isStreaming, isTrue);
      expect(seen, isEmpty);

      teardownLink(async, link);
    });
  });

  test('demo device serves the fixture calibration document', () {
    fakeAsync((async) {
      DeviceFlash? served;
      final (link, seen) = wire(onDeviceFlash: (flash) => served = flash);
      settleStartup(async);

      unawaited(link.connectToDemoDevice());
      async.elapse(const Duration(milliseconds: 100));
      final fixture = flashFromDoc(
        demoBoardCalibrationDoc,
        pgaGains: const [1, 1, 1, 1],
      );
      expect(served!.kvs.factory, fixture.kvs.factory);
      expect(served!.kvs.user, fixture.kvs.user);
      expect(served!.board, isA<ProvisionedBoardCalibration>());

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(milliseconds: 100));
      expect(seen, isEmpty);
    });
  });

  test('demo device streams and disconnects cleanly', () {
    fakeAsync((async) {
      var received = 0;
      final (link, seen) = wire(onAdcData: (_) => received++);
      // Drain the constructor's two availability queries (see [settleStartup])
      // — this test's own work is only ~200 ms of fake time, well under the
      // ~400 ms they need, and their pending timers would otherwise wedge the
      // shared 'global' queue bucket (availability + scan commands) for every
      // later test in the file.
      settleStartup(async);

      unawaited(link.connectToDemoDevice());
      async.elapse(const Duration(milliseconds: 100));
      expect(link.isStreaming, isTrue);
      expect(received, greaterThan(0));

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(milliseconds: 100));
      expect(link.linkState, BtLinkState.idle);
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
      expect(link.linkState, BtLinkState.idle);

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
      expect(link.linkState, BtLinkState.idle);
      expect(seen, isEmpty);

      // A late duplicate disconnect event arrives after the link is idle.
      // It must not touch state, notify, or re-stamp the settle window.
      var notifies = 0;
      link.addListener(() => notifies++);
      MockBlePlatform.instance.updateConnection(deviceId, false);
      async.flushMicrotasks();

      expect(link.linkState, BtLinkState.idle);
      expect(notifies, 0);
      expect(seen, isEmpty);
    });
  });

  group('lastAliveMs', () {
    // NOTE on time: fakeAsync fakes timers and package:clock, NOT
    // DateTime.now() — stamps therefore carry real wall-clock times taken
    // milliseconds apart, so ordering assertions use >= (the exact-age and
    // fold ordering logic lives in ble_row_subtitle_test.dart).
    test('is null for a device never scanned or connected', () {
      fakeAsync((async) {
        final (link, _) = wire();
        settleStartup(async);
        expect(link.lastAliveMs(deviceId), isNull);
      });
    });

    test('scan results feed it via the advert-timestamp fold (native)', () {
      fakeAsync((async) {
        final (link, _) = wire();
        settleStartup(async);

        unawaited(link.toggleScan());
        async.elapse(const Duration(seconds: 3));
        expect(link.devices, isNotEmpty);
        expect(link.lastAliveMs(deviceId), isNotNull);

        unawaited(link.toggleScan());
        async.elapse(const Duration(milliseconds: 100));
      });
    });

    test('a live link stamps it; a failed connect stamps nothing', () {
      fakeAsync((async) {
        final (link, _) = wire();
        async.elapse(const Duration(milliseconds: 300));

        // A refused connect proves nothing about the device being alive.
        MockBlePlatform.instance.failConnect = true;
        unawaited(link.connectToDevice(deviceId).catchError((_) {}));
        async.elapse(const Duration(seconds: 2));
        expect(link.lastAliveMs(deviceId), isNull);

        // Reaching streaming is a proof of life.
        MockBlePlatform.instance.failConnect = false;
        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));
        expect(link.isStreaming, isTrue);
        final connectedAt = link.lastAliveMs(deviceId);
        expect(connectedAt, isNotNull);

        // Teardown re-stamps: proof of life ends at disconnect, not at
        // connect (>=, not > — see the fakeAsync time note above).
        unawaited(link.disconnectSelectedDevice());
        async.elapse(const Duration(seconds: 4));
        expect(link.lastAliveMs(deviceId), greaterThanOrEqualTo(connectedAt!));
      });
    });

    test('a user-requested disconnect re-stamps proof of life', () {
      fakeAsync((async) {
        final (link, _) = wire();
        settleStartup(async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));
        expect(link.isStreaming, isTrue);
        final connectedAt = link.lastAliveMs(deviceId);

        // Burn real wall-clock time so the two stamps can differ: fakeAsync
        // fakes timers, NOT DateTime.now() (see the group note), and real
        // execution between them takes microseconds — below Windows' ~15.6 ms
        // clock granularity. A synchronous spin keeps the fake zone intact
        // (no timers or microtasks involved).
        final sw = Stopwatch()..start();
        while (sw.elapsedMilliseconds < 50) {}

        unawaited(link.disconnectSelectedDevice());
        async.elapse(const Duration(seconds: 4));

        expect(link.linkState, BtLinkState.idle);
        // Strictly greater: the stamp moved from connect time to disconnect
        // time. Before the fix, a user-requested disconnect stamped nothing
        // (the callback sees `disconnecting`, not an active state), so a row
        // connected minutes ago instantly showed "Last seen >1 minute ago".
        expect(link.lastAliveMs(deviceId), greaterThan(connectedAt!));
      });
    });

    test('the demo device is never stamped', () {
      fakeAsync((async) {
        final (link, _) = wire();
        settleStartup(async);

        unawaited(link.connectToDemoDevice());
        async.elapse(const Duration(milliseconds: 100));
        unawaited(link.disconnectSelectedDevice());
        async.elapse(const Duration(milliseconds: 100));

        expect(link.linkState, BtLinkState.idle);
        expect(link.lastAliveMs('demo_device'), isNull);
      });
    });
  });
}
