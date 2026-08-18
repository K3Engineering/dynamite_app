import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/services/bt_device_config.dart';
import 'package:dynamite_app/services/kvs_client.dart';
import 'package:dynamite_app/services/kvs_protocol.dart';
import 'package:dynamite_app/services/mockble.dart';

/// Tests for [KvsClient] against [MockBlePlatform]'s KVS emulation, driven
/// deterministically with [fakeAsync]. The mock answers KVS writes
/// synchronously, so ordinary commands resolve within a microtask flush;
/// timing paths (timeout, abort) use explicit elapses.
void main() {
  const deviceId = '2';

  KvsClient wire() {
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.resetKnobs();
    final client = KvsClient(
      write: (bytes) =>
          UniversalBle.write(deviceId, btServiceId, btChrKvs, bytes),
    );
    UniversalBle.onValueChange = (deviceId, characteristicId, data, timestamp) {
      if (characteristicId == btChrKvs) client.handleNotification(data);
    };
    return client;
  }

  final mock = MockBlePlatform.instance;

  /// Capture a command future's error into [errors] (its value is dropped).
  void track(Future<Object?> f, List<Object> errors) {
    unawaited(f.then((_) {}, onError: (Object e) => errors.add(e)));
  }

  /// Put the mock into the firmware's locked state: KVS commands are
  /// silently dropped while the ADC feed subscription is held.
  void lockDevice() {
    mock.kvsLockWhenStreaming = true;
    unawaited(
      MockBlePlatform.instance.setNotifiable(
        deviceId,
        btServiceId,
        btChrAdcFeedId,
        BleInputProperty.notification,
      ),
    );
  }

  void unlockDevice() {
    unawaited(
      MockBlePlatform.instance.setNotifiable(
        deviceId,
        btServiceId,
        btChrAdcFeedId,
        BleInputProperty.disabled,
      ),
    );
  }

  test('get returns the stored value; a missing key returns null', () {
    fakeAsync((async) {
      final client = wire();
      String? value;
      Object? missing = 'unset';
      unawaited(client.get(kvsFolderFactory, 'ch0.r').then((v) => value = v));
      unawaited(client.get(kvsFolderFactory, 'nope').then((v) => missing = v));
      async.flushMicrotasks();

      expect(value, mock.kvsStore[kvsFolderFactory]!['ch0.r']);
      expect(missing, isNull);
    });
  });

  test('concurrent commands are serialized and all resolve', () {
    fakeAsync((async) {
      final client = wire();
      final values = <String?>[];
      unawaited(
        Future.wait([
          client.get(kvsFolderFactory, 'ch0.raw'),
          client.get(kvsFolderFactory, 'ch1.raw'),
          client.get(kvsFolderUser, 'lc0.name'),
        ]).then(values.addAll),
      );
      async.flushMicrotasks();

      expect(values, [
        mock.kvsStore[kvsFolderFactory]!['ch0.raw'],
        mock.kvsStore[kvsFolderFactory]!['ch1.raw'],
        'Thrust cell',
      ]);
    });
  });

  test('set stores the value; client-side validation rejects bad input', () {
    fakeAsync((async) {
      final client = wire();
      bool? ok;
      unawaited(client.set(kvsFolderUser, 'lc9.cap', '50').then((v) => ok = v));
      async.flushMicrotasks();

      expect(ok, isTrue);
      expect(mock.kvsStore[kvsFolderUser]!['lc9.cap'], '50');

      final errors = <Object>[];
      track(client.set(kvsFolderUser, 'lc9.cap', ''), errors);
      track(client.set(kvsFolderUser, 'key-that-is-too-long', '1'), errors);
      async.flushMicrotasks();
      expect(errors, hasLength(2));
      expect(errors, everyElement(isA<ArgumentError>()));
    });
  });

  test('delete removes a key; deleting a missing key answers false', () {
    fakeAsync((async) {
      final client = wire();
      bool? existed;
      bool? again = true;
      unawaited(
        client.delete(kvsFolderUser, 'lc4.cap').then((v) => existed = v),
      );
      async.flushMicrotasks();

      expect(existed, isTrue);
      expect(mock.kvsStore[kvsFolderUser]!.containsKey('lc4.cap'), isFalse);

      unawaited(client.delete(kvsFolderUser, 'lc4.cap').then((v) => again = v));
      async.flushMicrotasks();
      expect(again, isFalse);
    });
  });

  test('listKeys enumerates a folder and stops at the first rejection', () {
    fakeAsync((async) {
      final client = wire();
      Map<String, int>? keys;
      unawaited(client.listKeys(kvsFolderUser).then((v) => keys = v));
      async.flushMicrotasks();

      expect(keys, isNotNull);
      expect(keys!.keys, unorderedEquals(mock.kvsStore[kvsFolderUser]!.keys));
      expect(keys!.values, everyElement(0x21));
      // Iteration ends with one rejected IDX past the last entry.
      final idxCommands = mock.kvsCommandLog
          .where((c) => c.startsWith(kvsCmdIndex))
          .toList();
      expect(idxCommands, hasLength(mock.kvsStore[kvsFolderUser]!.length + 1));
      expect(
        idxCommands.last,
        encodeKvsIndex(kvsFolderUser, mock.kvsStore[kvsFolderUser]!.length),
      );
    });
  });

  test('a silently dropped command times out; the queue recovers', () {
    fakeAsync((async) {
      final client = wire();
      lockDevice();

      final errors = <Object>[];
      track(client.get(kvsFolderFactory, 'ch0.r'), errors);
      async.elapse(const Duration(seconds: 4));

      expect(errors, hasLength(1));
      expect(errors.single, isA<TimeoutException>());

      // The timed-out command did not wedge the queue: after the device
      // unlocks, a fresh command resolves normally.
      unlockDevice();
      String? value;
      unawaited(client.get(kvsFolderFactory, 'ch0.r').then((v) => value = v));
      async.flushMicrotasks();
      expect(value, mock.kvsStore[kvsFolderFactory]!['ch0.r']);
    });
  });

  test('abort fails pending and queued commands, then refuses new ones', () {
    fakeAsync((async) {
      final client = wire();
      lockDevice();

      final errors = <Object>[];
      track(
        client.get(kvsFolderFactory, 'ch0.r'),
        errors,
      ); // stuck awaiting a response
      track(client.set(kvsFolderUser, 'lc9.cap', '1'), errors); // queued
      async.flushMicrotasks();

      client.abort();
      async.flushMicrotasks();
      expect(errors, hasLength(2));

      // The client is spent: later commands fail immediately instead of
      // touching the wire.
      mock.kvsCommandLog.clear();
      track(client.get(kvsFolderFactory, 'ch0.r'), errors);
      async.flushMicrotasks();
      expect(errors, hasLength(3));
      expect(mock.kvsCommandLog, isEmpty);
    });
  });
}
