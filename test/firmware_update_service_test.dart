import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/firmware_release.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/demo_device.dart';
import 'package:dynamite_app/services/firmware_catalog.dart';
import 'package:dynamite_app/services/firmware_update_service.dart';
import 'helpers/mockble.dart';

/// A catalog serving a fixed target, whatever the channel.
class _FixedCatalog implements FirmwareCatalog {
  _FixedCatalog(this.target);

  final FirmwareRelease? target;

  @override
  Future<FirmwareRelease?> latestFor({
    required FirmwareChannel channel,
  }) async => target;

  @override
  Future<Uint8List> downloadImage(FirmwareRelease release) =>
      throw UnimplementedError('tests never download');
}

/// A catalog whose check always fails (fetch trouble).
class _ErrorCatalog implements FirmwareCatalog {
  @override
  Future<FirmwareRelease?> latestFor({required FirmwareChannel channel}) =>
      throw StateError('fetch failed');

  @override
  Future<Uint8List> downloadImage(FirmwareRelease release) =>
      throw UnimplementedError('tests never download');
}

FirmwareRelease _release(String tag) => FirmwareRelease(
  tag: tag,
  version: FirmwareVersion.tryParse(tag) ?? const FirmwareVersion(0, 0, 1),
  assetName: 'image.bin',
  size: 1,
  downloadUrl: Uri.parse('https://example.com/$tag.bin'),
  sha256Url: Uri.parse('https://example.com/$tag.sha256'),
);

/// Tests for [FirmwareUpdateService] against [MockBlePlatform], same
/// fake-async harness as ble_link_manager_test. The mock device reports
/// firmware `v700P|mock-1.0.0` (its DIS table), so every check compares
/// against the describe `mock-1.0.0`.
void main() {
  const deviceId = '2';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.resetKnobs();
  });

  /// Manager + service + event collector, built INSIDE the fake clock (the
  /// manager's startup timers must belong to it — see ble_link_manager_test).
  /// Mock prefs resolve in microtasks, so a flush is enough.
  (BleLinkManager, FirmwareUpdateService, List<AppEvent>) wire(
    FakeAsync async,
  ) {
    SharedPreferences? prefs;
    unawaited(SharedPreferences.getInstance().then((p) => prefs = p));
    async.flushMicrotasks();
    final events = AppEvents();
    final seen = <AppEvent>[];
    final sub = events.stream.listen(seen.add);
    addTearDown(() => unawaited(sub.cancel()));
    final link = BleLinkManager(
      events: events,
      demo: DemoDevice(),
      onDeviceFlash: (_) {},
      onAdcData: (_) {},
      onSampleRate: (_) {},
    );
    final service = FirmwareUpdateService(
      prefs: prefs!,
      link: link,
      events: events,
      catalog: _FixedCatalog(null),
    );
    return (link, service, seen);
  }

  /// In-scope link teardown, as ble_link_manager_test's.
  void disconnectElapse(FakeAsync async, BleLinkManager link) {
    MockBlePlatform.instance.hangDisconnect = false;
    unawaited(link.disconnectSelectedDevice());
    async.elapse(const Duration(seconds: 4));
  }

  test('a noted flash tag publishes a verified event on the next check', () {
    fakeAsync((async) {
      final (link, service, seen) = wire(async);
      service.catalog = _FixedCatalog(_release('mock-1.0.0'));

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      // The connect's auto-check ran and the device matches the target:
      // nothing to say.
      expect(service.checkState, isA<CheckOk>());
      expect(seen, isEmpty);

      service.noteFlashAccepted('mock-1.0.0');
      disconnectElapse(async, link);
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      // The reconnect's check confirmed the flashed tag — exactly once
      // (the pend is consumed).
      expect(seen.whereType<FirmwareFlashVerified>(), hasLength(1));
      expect(seen.whereType<FirmwareUpdateAvailable>(), isEmpty);
      disconnectElapse(async, link);
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(seen.whereType<FirmwareFlashVerified>(), hasLength(1));

      disconnectElapse(async, link);
    });
  });

  test('a flash the device does not confirm re-flags the update banner', () {
    fakeAsync((async) {
      final (link, service, seen) = wire(async);
      service.catalog = _FixedCatalog(_release('v9.9.9'));

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      // Installed mock-1.0.0 vs target v9.9.9: first banner.
      expect(seen.whereType<FirmwareUpdateAvailable>(), hasLength(1));

      // Flashed v9.9.9 but the rebooted device still reports mock-1.0.0:
      // the rollback path — pend consumed, banner re-raised, and NEVER a
      // verification.
      service.noteFlashAccepted('v9.9.9');
      disconnectElapse(async, link);
      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(seen.whereType<FirmwareFlashVerified>(), isEmpty);
      expect(seen.whereType<FirmwareUpdateAvailable>(), hasLength(2));

      disconnectElapse(async, link);
    });
  });

  test('a failed re-check erases the previous result', () {
    fakeAsync((async) {
      final (link, service, seen) = wire(async);
      service.catalog = _FixedCatalog(_release('mock-1.0.0'));

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(service.checkState, isA<CheckOk>());

      service.catalog = _ErrorCatalog();
      unawaited(service.checkForUpdates());
      async.flushMicrotasks();
      expect(service.checkState, isA<CheckFailed>());
      expect(seen, isEmpty);

      disconnectElapse(async, link);
    });
  });
}
