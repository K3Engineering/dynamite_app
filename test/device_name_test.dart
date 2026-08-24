import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/device_name.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/kvs_protocol.dart';
import 'package:dynamite_app/services/mockble.dart';

/// Link-level tests for the Settings-namespace device name: the connect-time
/// read, the display-name overlay, and the [BleLinkManager.setDeviceName]
/// write path, over MockBlePlatform (fakeAsync, like mockble_test.dart).
void main() {
  // The mock device that advertises the ADC service (see _generateServices).
  const deviceId = '2';

  final mock = MockBlePlatform.instance;

  (BleLinkManager, VoidCallback) wire({required FakeAsync async}) {
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.resetKnobs();
    final link = BleLinkManager(events: AppEvents());
    return (
      link,
      () {
        // Best-effort disconnect so the mock's timers are cancelled and the
        // singleton is left idle for the next test.
        unawaited(link.disconnectSelectedDevice());
        async.elapse(const Duration(seconds: 4));
      },
    );
  }

  /// Drives setDeviceName to completion under fakeAsync; returns its result
  /// (or the thrown error as an [Error]).
  Object? setName(BleLinkManager link, String name, FakeAsync async) {
    Object? result;
    unawaited(
      link
          .setDeviceName(name)
          .then((ok) => result = ok, onError: (Object e) => result = e),
    );
    async.elapse(const Duration(seconds: 1));
    return result;
  }

  test('connect reads the stored name and overlays the display name', () {
    fakeAsync((async) {
      final (link, teardown) = wire(async: async);
      // Seeded after wire(): resetKnobs() re-seeds the store from the demo doc.
      mock.kvsStore[kvsFolderSettings]![kvsKeyDeviceName] = 'Rack 4';

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(link.isStreaming, isTrue);
      expect(link.connectedStoredDeviceName, 'Rack 4');
      expect(link.connectedDeviceName, 'Rack 4');

      teardown();
      // The overlay dies with the link.
      expect(link.connectedStoredDeviceName, isNull);
      expect(link.connectedDeviceName, isEmpty);
    });
  });

  test('no stored name: display falls back to the advertised name', () {
    fakeAsync((async) {
      final (link, teardown) = wire(async: async);

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(link.isStreaming, isTrue);
      expect(link.connectedStoredDeviceName, isNull);
      // Connect without a prior scan: the name falls back to the device id.
      expect(link.connectedDeviceName, '2');

      teardown();
    });
  });

  test('setDeviceName writes, overlays, and clearing reverts', () {
    fakeAsync((async) {
      final (link, teardown) = wire(async: async);

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));

      expect(setName(link, 'Bench 2', async), true);
      expect(mock.kvsStore[kvsFolderSettings]![kvsKeyDeviceName], 'Bench 2');
      expect(link.connectedStoredDeviceName, 'Bench 2');
      expect(link.connectedDeviceName, 'Bench 2');
      // Surrounding whitespace is input hygiene, never stored.
      expect(setName(link, '  Bench 3  ', async), true);
      expect(mock.kvsStore[kvsFolderSettings]![kvsKeyDeviceName], 'Bench 3');

      // Empty clears the key (a DEL); the display reverts to the fallback.
      expect(setName(link, '   ', async), true);
      expect(
        mock.kvsStore[kvsFolderSettings]!.containsKey(kvsKeyDeviceName),
        isFalse,
      );
      expect(link.connectedStoredDeviceName, isNull);
      expect(link.connectedDeviceName, '2');

      teardown();
    });
  });

  test('a stored name survives reconnect (served at the next connect)', () {
    fakeAsync((async) {
      final (link, teardown) = wire(async: async);

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(setName(link, 'Rack 4', async), true);
      teardown();
      expect(link.connectedDeviceName, isEmpty);

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.connectedStoredDeviceName, 'Rack 4');
      expect(link.connectedDeviceName, 'Rack 4');

      teardown();
    });
  });

  test('invalid names are rejected before any write', () {
    fakeAsync((async) {
      final (link, teardown) = wire(async: async);

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      mock.kvsCommandLog.clear();

      expect(setName(link, 'Bad,Name', async), isA<ArgumentError>());
      expect(
        setName(link, 'A' * (deviceNameMaxLength + 1), async),
        isA<ArgumentError>(),
      );
      expect(setName(link, 'Bad\nName', async), isA<ArgumentError>());
      expect(mock.kvsCommandLog, isEmpty);
      expect(mock.kvsStore[kvsFolderSettings], isEmpty);

      teardown();
    });
  });

  test('setDeviceName with no device connected throws', () {
    fakeAsync((async) {
      final (link, _) = wire(async: async);
      expect(setName(link, 'Rack 4', async), isA<StateError>());
    });
  });
}
