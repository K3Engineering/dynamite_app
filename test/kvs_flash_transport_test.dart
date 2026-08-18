import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/services/bt_device_config.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/kvs_client.dart';
import 'package:dynamite_app/services/kvs_flash_transport.dart';
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
    final client = KvsClient(deviceId: deviceId);
    UniversalBle.onValueChange = (deviceId, characteristicId, data, timestamp) {
      if (characteristicId == btChrKvs) client.handleNotification(data);
    };
    return (KvsFlashTransport(client), client);
  }

  final mock = MockBlePlatform.instance;

  String? read(KvsFlashTransport transport, FakeAsync async) {
    String? doc;
    unawaited(transport.readFlashDoc().then((d) => doc = d));
    async.flushMicrotasks();
    return doc;
  }

  Object? write(KvsFlashTransport transport, String doc, FakeAsync async) {
    Object? error;
    unawaited(
      transport
          .writeFlashDoc(doc)
          .then((_) {}, onError: (Object e) => error = e),
    );
    async.flushMicrotasks();
    return error;
  }

  test('readFlashDoc reassembles the seeded document', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      final doc = read(transport, async);

      expect(doc, isNotNull);
      final flash = DeviceFlash.parse(doc!);
      final fixture = DeviceFlash.parse(demoBoardCalibrationDoc);
      expect(flash.board.factoryDate, fixture.board.factoryDate);
      expect(flash.board.excitationMv, fixture.board.excitationMv);
      expect(flash.board.channels.every((c) => c.isFactoryCalibrated), isTrue);
      expect(flash.board.channels[0].offsetCounts, closeTo(845.2, 1e-9));
      expect(flash.slots, fixture.slots);
    });
  });

  test('a write with unchanged content issues no commands', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      final doc = read(transport, async)!;
      mock.kvsCommandLog.clear();

      expect(write(transport, doc, async), isNull);
      expect(mock.kvsCommandLog, isEmpty);
    });
  });

  test('writes are a minimal, folder-routed diff', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      final doc = read(transport, async)!;
      mock.kvsCommandLog.clear();

      // Change one slot value, empty slot 5, add slot 7.
      final modified =
          '${doc.split('\n').where((l) => !l.startsWith('lc4.')).join('\n').replaceFirst('lc0.sens=1.9993', 'lc0.sens=1.9985')}\nlc6.cap=50\nlc6.sens=2';

      expect(write(transport, modified, async), isNull);

      // Only the changed keys were touched: two SETs for the new slot, one
      // for the edited value, three DELs for the emptied slot — all in U,
      // nothing in F.
      expect(mock.kvsCommandLog, [
        'SETUlc0.sens=1.9985',
        'SETUlc6.cap=50',
        'SETUlc6.sens=2',
        'DELUlc4.name',
        'DELUlc4.cap',
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

  test('unknown keys round-trip to the folder they came from', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      // A key the model doesn't know, planted in the Factory folder.
      mock.kvsStore[kvsFolderFactory]!['vendor.x'] = '42';
      final doc = read(transport, async)!;
      expect(doc, contains('vendor.x=42'));
      mock.kvsCommandLog.clear();

      // An unrelated edit leaves the unknown key alone (it re-emits into
      // the document, matches the snapshot, and is never rewritten).
      final modified = doc.replaceFirst('lc0.sens=1.9993', 'lc0.sens=1.9985');
      expect(write(transport, modified, async), isNull);
      expect(mock.kvsCommandLog.where((c) => c.contains('vendor.x')), isEmpty);
      expect(mock.kvsStore[kvsFolderFactory]!['vendor.x'], '42');

      // Dropping it from the document deletes it from ITS folder.
      mock.kvsCommandLog.clear();
      final stripped = modified
          .split('\n')
          .where((l) => !l.startsWith('vendor.x'))
          .join('\n');
      expect(write(transport, stripped, async), isNull);
      expect(mock.kvsCommandLog, contains('DELFvendor.x'));
      expect(mock.kvsStore[kvsFolderFactory]!.containsKey('vendor.x'), isFalse);
    });
  });

  test('a write without a prior read writes every key', () {
    fakeAsync((async) {
      final (transport, client) = wire();
      // Empty the device, then write the fixture doc with no snapshot.
      mock.kvsStore.forEach((_, folder) => folder.clear());
      expect(write(transport, demoBoardCalibrationDoc, async), isNull);

      // Everything landed, folder-routed.
      expect(mock.kvsStore[kvsFolderFactory]!['ch0.raw'], isNotNull);
      expect(mock.kvsStore[kvsFolderUser]!['lc0.name'], 'Thrust cell');
      expect(mock.kvsStore[kvsFolderSettings], isEmpty);

      // And a fresh read reassembles the same content.
      final reread = read(KvsFlashTransport(client), async)!;
      expect(
        DeviceFlash.parse(reread).slots,
        DeviceFlash.parse(demoBoardCalibrationDoc).slots,
      );
    });
  });

  test('read failure returns null; write failure throws', () {
    fakeAsync((async) {
      final (transport, _) = wire();
      mock.failCalibrationRead = true;

      expect(read(transport, async), isNull);
      expect(
        write(transport, demoBoardCalibrationDoc, async),
        isA<StateError>(),
      );
    });
  });
}
