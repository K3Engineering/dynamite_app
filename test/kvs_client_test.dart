import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/services/bt_device_config.dart';
import 'package:dynamite_app/services/kvs_client.dart';
import 'package:dynamite_app/services/kvs_protocol.dart';
import 'helpers/mockble.dart';

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
  /// answered 'B' (busy) while the ADC feed subscription is held.
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

  /// A dead link: KVS commands go unanswered, so they ride out the command
  /// timeout.
  void silenceDevice() {
    mock.kvsDropCommands = true;
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

  test('an unanswered command times out; the queue recovers', () {
    fakeAsync((async) {
      final client = wire();
      silenceDevice();

      final errors = <Object>[];
      track(client.get(kvsFolderFactory, 'ch0.r'), errors);
      async.elapse(const Duration(seconds: 4));

      expect(errors, hasLength(1));
      expect(errors.single, isA<TimeoutException>());

      // The timed-out command did not wedge the queue: once the link
      // answers again, a fresh command resolves normally.
      mock.kvsDropCommands = false;
      String? value;
      unawaited(client.get(kvsFolderFactory, 'ch0.r').then((v) => value = v));
      async.flushMicrotasks();
      expect(value, mock.kvsStore[kvsFolderFactory]!['ch0.r']);
    });
  });

  test('a busy answer fails fast; unlocked, the command resolves', () {
    fakeAsync((async) {
      final client = wire();
      lockDevice();

      // No 3 s ride-out: the 'B' answer settles the command immediately.
      final errors = <Object>[];
      track(client.get(kvsFolderFactory, 'ch0.r'), errors);
      async.flushMicrotasks();

      expect(errors, hasLength(1));
      expect(errors.single, isA<KvsBusyException>());

      unlockDevice();
      String? value;
      unawaited(client.get(kvsFolderFactory, 'ch0.r').then((v) => value = v));
      async.flushMicrotasks();
      expect(value, mock.kvsStore[kvsFolderFactory]!['ch0.r']);
    });
  });

  test('a device-error answer fails the command with KvsDeviceException', () {
    fakeAsync((async) {
      final client = wire();
      // Hold the write window open so the 'E' frame can be injected.
      mock.kvsCommandDelay = const Duration(seconds: 1);

      final errors = <Object>[];
      track(client.get(kvsFolderFactory, 'ch0.r'), errors);
      async.flushMicrotasks();
      client.handleNotification(Uint8List.fromList(utf8.encode('EGETFch0.r')));
      async.flushMicrotasks();

      expect(errors, hasLength(1));
      expect(errors.single, isA<KvsDeviceException>());
      // The mock's own late answer drops quietly.
      async.elapse(const Duration(seconds: 2));
    });
  });

  test('abort fails pending and queued commands, then refuses new ones', () {
    fakeAsync((async) {
      final client = wire();
      silenceDevice();

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

  test('stale frames for other commands are dropped; the live command '
      'resolves', () {
    fakeAsync((async) {
      final client = wire();
      // The mock answers when the write completes 1 s out, leaving a window
      // where 'GETFch0.r' is live and foreign frames can be injected.
      mock.kvsCommandDelay = const Duration(seconds: 1);

      String? value;
      unawaited(client.get(kvsFolderFactory, 'ch0.r').then((v) => value = v));
      async.flushMicrotasks();

      // None of these answers the live command: a shorter reject, a longer
      // reject, a different key's success, the prefix trap (the strict
      // prefix's late success frame), and another command's busy/error.
      client.handleNotification(Uint8List.fromList(utf8.encode('0GETFch0')));
      client.handleNotification(Uint8List.fromList(utf8.encode('0GETFch0.rX')));
      client.handleNotification(
        Uint8List.fromList(utf8.encode('1GETFch1.r=9')),
      );
      client.handleNotification(Uint8List.fromList(utf8.encode('1GETFch0=9')));
      client.handleNotification(Uint8List.fromList(utf8.encode('BGETFch1.r')));
      client.handleNotification(Uint8List.fromList(utf8.encode('EGETFch1.r')));
      async.elapse(const Duration(seconds: 2));

      expect(value, mock.kvsStore[kvsFolderFactory]!['ch0.r']);
    });
  });

  test("a timed-out command's late frame does not poison the next command", () {
    fakeAsync((async) {
      final client = wire();
      silenceDevice();
      final errors = <Object>[];
      track(
        client.get(kvsFolderFactory, 'ch0'),
        errors,
      ); // unanswered, times out
      async.elapse(const Duration(seconds: 4));
      expect(errors, hasLength(1));

      mock.kvsDropCommands = false;
      mock.kvsCommandDelay = const Duration(seconds: 1);
      String? value;
      unawaited(client.get(kvsFolderFactory, 'ch0.r').then((v) => value = v));
      async.flushMicrotasks();
      // The timed-out 'GETFch0's late reply lands while 'GETFch0.r' is live.
      client.handleNotification(
        Uint8List.fromList(utf8.encode('1GETFch0=stale')),
      );
      async.elapse(const Duration(seconds: 2));

      expect(errors, hasLength(1));
      expect(value, mock.kvsStore[kvsFolderFactory]!['ch0.r']);
    });
  });

  test('a duplicate frame in the write window does not throw', () {
    fakeAsync((async) {
      final client = wire();
      // The firmware notifies before the ATT write response, so a frame can
      // land while the write is still awaited; a duplicate must be dropped,
      // not double-complete the completer.
      mock.kvsCommandDelay = const Duration(seconds: 1);

      String? value;
      unawaited(client.get(kvsFolderFactory, 'ch0.r').then((v) => value = v));
      async.flushMicrotasks();

      final f = Uint8List.fromList(utf8.encode('1GETFch0.r=1,2,3'));
      client.handleNotification(f);
      expect(() => client.handleNotification(f), returnsNormally);
      async.flushMicrotasks();
      expect(value, '1,2,3');
      // The mock's own frame lands afterwards and drops quietly as well.
      async.elapse(const Duration(seconds: 2));
    });
  });

  test('a byte-identical late frame is accepted as the live answer', () {
    fakeAsync((async) {
      // The protocol has no transaction ID: a stale frame byte-identical to
      // the live command's answer is indistinguishable from that answer.
      // Accepting it is correct — KVS commands are idempotent, and the
      // device did execute that exact command.
      final client = wire();
      mock.kvsCommandDelay = const Duration(seconds: 1);

      String? value;
      unawaited(client.get(kvsFolderFactory, 'ch0.r').then((v) => value = v));
      async.flushMicrotasks();
      client.handleNotification(
        Uint8List.fromList(utf8.encode('1GETFch0.r=stale-value')),
      );
      async.flushMicrotasks();
      expect(value, 'stale-value');
      async.elapse(const Duration(seconds: 2));
    });
  });

  test('frames arriving after abort are dropped without error', () {
    fakeAsync((async) {
      final client = wire();
      silenceDevice();
      final errors = <Object>[];
      track(client.get(kvsFolderFactory, 'ch0.r'), errors);
      async.flushMicrotasks();

      client.abort();
      final f = Uint8List.fromList(utf8.encode('1GETFch0.r=1'));
      expect(() => client.handleNotification(f), returnsNormally);
      async.flushMicrotasks();
      expect(errors, hasLength(1));
    });
  });
}
