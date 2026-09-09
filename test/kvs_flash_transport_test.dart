import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/services/bt_device_config.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/kvs_client.dart';
import 'package:dynamite_app/services/gatt_link_backend.dart';
import 'package:dynamite_app/services/kvs_protocol.dart';
import 'package:dynamite_app/services/mockble.dart';

/// Tests for [KvsFlashTransport]: the document-level view over the per-key
/// KVS, against [MockBlePlatform]'s KVS emulation (fakeAsync, like
/// kvs_client_test.dart).
void main() {
  const deviceId = '2';

  (KvsFlashTransport, KvsClient) wire() {
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.resetKnobs();
    final client = KvsClient(
      write: (bytes) =>
          UniversalBle.write(deviceId, btServiceId, btChrKvs, bytes),
    );
    UniversalBle.onValueChange = (deviceId, characteristicId, data, timestamp) {
      if (characteristicId == btChrKvs) client.handleNotification(data);
    };
    return (KvsFlashTransport(client), client);
  }

  final mock = MockBlePlatform.instance;

  KvsSnapshot? read(KvsFlashTransport transport, FakeAsync async) {
    KvsSnapshot? snapshot;
    unawaited(transport.readKvsSnapshot().then((s) => snapshot = s));
    async.flushMicrotasks();
    return snapshot;
  }

  Object? writeSlots(
    KvsFlashTransport transport,
    Map<String, String> lcKeys,
    FakeAsync async,
  ) {
    Object? error;
    unawaited(
      transport
          .writeSlots(lcKeys)
          .then((_) {}, onError: (Object e) => error = e),
    );
    async.flushMicrotasks();
    return error;
  }

  /// The fixture document's slot keys, exactly as a save would emit them.
  Map<String, String> fixtureSlots() => DeviceFlash.parse(
    demoBoardCalibrationDoc,
    pgaGains: const [1, 1, 1, 1],
  ).slots.toKv();

  test('readKvsSnapshot reads the seeded store folder-separated', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      final snapshot = read(transport, async);

      expect(snapshot, isNotNull);
      expect(snapshot!.factory['adc_fsr'], '1.2,nominal');
      expect(snapshot.user['lc0.cap'], '200');
      const gains = [1.0, 1.0, 1.0, 1.0];
      final flash = DeviceFlash.fromKvs(snapshot, pgaGains: gains);
      final fixture = DeviceFlash.parse(
        demoBoardCalibrationDoc,
        pgaGains: gains,
      );
      final board = flash.board as ProvisionedBoardCalibration;
      final fixtureBoard = fixture.board as ProvisionedBoardCalibration;
      expect(board.factoryDate, fixtureBoard.factoryDate);
      expect(board.channels.every((c) => c.isFactoryCalibrated), isTrue);
      expect(
        (board.channels[0] as CalibratedChannelBoard).offsetCounts,
        closeTo(845.2, 1e-9),
      );
      expect(flash.slots, fixture.slots);
    });
  });

  test('a write with unchanged content issues no commands', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      read(transport, async);
      mock.kvsCommandLog.clear();

      expect(writeSlots(transport, fixtureSlots(), async), isNull);
      expect(mock.kvsCommandLog, isEmpty);
    });
  });

  test('writes are a minimal, User-folder diff of slot keys only', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      read(transport, async);
      mock.kvsCommandLog.clear();

      // Change one slot value, empty slot 5, add slot 7.
      final modified = fixtureSlots()
        ..['lc0.sens'] = '1.9985'
        ..remove('lc4.name')
        ..remove('lc4.cap')
        ..remove('lc4.sens')
        ..['lc6.cap'] = '50'
        ..['lc6.sens'] = '2';

      expect(writeSlots(transport, modified, async), isNull);

      // Only the changed keys were touched: two SETs for the new slot, one
      // for the edited value, three DELs for the emptied slot — all in U,
      // nothing in F.
      expect(mock.kvsCommandLog, [
        'SETUlc0.sens=1.9985',
        'SETUlc6.cap=50',
        'SETUlc6.sens=2',
        'DELUlc4.cap',
        'DELUlc4.name',
        'DELUlc4.sens',
      ]);

      final user = mock.kvsStore[kvsFolderUser]!;
      expect(user['lc0.sens'], '1.9985');
      expect(user['lc6.cap'], '50');
      expect(user.containsKey('lc4.cap'), isFalse);
      // The Factory folder (board calibration) was not part of the diff.
      expect(
        mock.kvsStore[kvsFolderFactory]!['ch0.raw'],
        parseFlashKv(demoBoardCalibrationDoc)['ch0.raw'],
      );
    });
  });

  test('unknown keys are never touched; non-slot keys are refused', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      // Keys the model doesn't know, planted in both folders.
      mock.kvsStore[kvsFolderFactory]!['vendor.x'] = '42';
      mock.kvsStore[kvsFolderUser]!['lc3.tare'] = '123';
      final snapshot = read(transport, async)!;
      expect(snapshot.factory['vendor.x'], '42');
      expect(snapshot.user['lc3.tare'], '123');
      mock.kvsCommandLog.clear();

      // A slot write leaves the unknown keys alone (slot writes only ever
      // name exact schema slot keys, and DELs are scoped to the same set).
      expect(writeSlots(transport, fixtureSlots(), async), isNull);
      expect(mock.kvsCommandLog, isEmpty);
      expect(mock.kvsStore[kvsFolderFactory]!['vendor.x'], '42');
      expect(mock.kvsStore[kvsFolderUser]!['lc3.tare'], '123');

      // A non-slot key can never be submitted to the device through here.
      expect(
        writeSlots(transport, {'vendor.x': '43'}, async),
        isA<ArgumentError>(),
      );
      expect(
        writeSlots(transport, {'lcx.cap': '1'}, async),
        isA<ArgumentError>(),
      );
      expect(mock.kvsStore[kvsFolderFactory]!['vendor.x'], '42');
      expect(mock.kvsStore[kvsFolderUser]!['lc3.tare'], '123');
    });
  });

  test('clearing the rig deletes schema slot keys only', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      mock.kvsStore[kvsFolderUser]!['lc3.tare'] = '123';
      read(transport, async);
      mock.kvsCommandLog.clear();

      expect(writeSlots(transport, const {}, async), isNull);
      expect(mock.kvsStore[kvsFolderUser]!['lc3.tare'], '123');
      expect(mock.kvsCommandLog.where((c) => c == 'DELUlc3.tare'), isEmpty);
      expect(mock.kvsStore[kvsFolderUser]!.containsKey('lc0.cap'), isFalse);
    });
  });

  test('a write without a prior read writes every slot key', () {
    fakeAsync((async) {
      final (transport, client) = wire();
      // Empty the device, then write slot keys with no snapshot (every key
      // is new; nothing is deleted without a snapshot to diff against).
      mock.kvsStore.forEach((_, folder) => folder.clear());
      const lcKeys = {
        'lc0.name': 'Thrust cell',
        'lc0.cap': '200',
        'lc0.sens': '1.9993',
      };
      expect(writeSlots(transport, lcKeys, async), isNull);

      // Everything landed in the User folder.
      expect(mock.kvsStore[kvsFolderUser]!['lc0.name'], 'Thrust cell');
      expect(mock.kvsStore[kvsFolderFactory], isEmpty);
      expect(mock.kvsStore[kvsFolderSettings], isEmpty);

      // And a fresh read reassembles the same slots.
      final reread = read(KvsFlashTransport(client), async)!;
      expect(
        DeviceFlash.fromKvs(reread, pgaGains: const [1, 1, 1, 1]).slots,
        DeviceFlash.parse(
          'lc0.name=Thrust cell\nlc0.cap=200\nlc0.sens=1.9993',
          pgaGains: const [1, 1, 1, 1],
        ).slots,
      );
    });
  });

  test('an empty KVS reads as an empty store (unprovisioned unit)', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      mock.kvsStore.forEach((_, folder) => folder.clear());

      final snapshot = read(transport, async)!;
      expect(snapshot.factory, isEmpty);
      expect(snapshot.user, isEmpty);
    });
  });

  test('read failure throws; write failure throws', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      mock.failKvsCommands = true;

      Object? readError;
      unawaited(
        transport.readKvsSnapshot().then(
          (_) {},
          onError: (Object e) => readError = e,
        ),
      );
      async.flushMicrotasks();
      expect(readError, isA<StateError>());

      expect(
        writeSlots(transport, {'lc0.cap': '100', 'lc0.sens': '2'}, async),
        isA<StateError>(),
      );
    });
  });
}
