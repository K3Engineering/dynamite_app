import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/rig_state.dart';

/// Tests for [RigState]: flash reads, pending edits (restore/discard across
/// reconnects), save/revert, and history. Transport is a fake capturing the
/// written document; SharedPreferences is mocked.
class _FakeTransport implements RigFlashTransport {
  String deviceId = 'dev1';
  String deviceName = 'Bench unit';
  String? lastWrittenDoc;
  bool failWrite = false;

  /// Served on read-back instead of the last written doc, to simulate a
  /// device that ignores or rewrites what it received.
  String? readBackDoc;

  /// When set, the write completes only once this gate does — lets a test
  /// land an edit while a save is in flight.
  Completer<void>? writeGate;

  @override
  String get connectedDeviceId => deviceId;

  @override
  String get connectedDeviceName => deviceName;

  @override
  Future<void> writeFlashDoc(String doc) async {
    if (failWrite) throw StateError('write failed');
    final gate = writeGate;
    if (gate != null) await gate.future;
    lastWrittenDoc = doc;
  }

  /// A faithful device serves back exactly what was last written.
  @override
  Future<String?> readFlashDoc() async => readBackDoc ?? lastWrittenDoc;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeTransport transport;

  Future<RigState> newRig() async => RigState(
    transport: transport,
    prefs: await SharedPreferences.getInstance(),
  );

  DeviceFlash fixture() => DeviceFlash.parse(demoBoardCalibrationDoc);

  /// The fixture doc with a recalibrated CH1 cell (sensitivity re-entered).
  String recalibratedDoc() => demoBoardCalibrationDoc.replaceFirst(
    'lc0.sens=1.9993',
    'lc0.sens=1.9985',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    transport = _FakeTransport();
  });

  group('flash reads', () {
    test('first read populates slots, titles and history', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());

      expect(rig.hasDeviceDoc, isTrue);
      expect(rig.channelTitles, [
        'Thrust cell',
        'Break jig',
        '100 kg · 2 mV/V',
        'CH 4',
      ]);
      expect(rig.channelCells[0]?.name, 'Thrust cell');
      expect(rig.hasPending, isFalse);
      // 3 channel cells + 1 spare were seen.
      expect(rig.history, hasLength(4));
    });

    test('a flash read with an empty device id is ignored', () async {
      final rig = await newRig();
      // A link that dropped mid-read delivers with no identity; the
      // document can't be attributed to anything.
      rig.onFlashRead('', '', fixture());
      expect(rig.hasDeviceDoc, isFalse);
      expect(rig.history, isEmpty);
    });

    test('boardCalibrationFor gates on document ownership', () async {
      final rig = await newRig();

      // No flash document read yet.
      expect(rig.boardCalibrationFor('dev1'), isNull);

      rig.onFlashRead('dev1', 'Bench unit', fixture());
      expect(rig.boardCalibrationFor('dev1'), isNotNull);
      // Any other device is refused.
      expect(rig.boardCalibrationFor('dev2'), isNull);
    });

    test('a changed device wins: readings use the new values', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        DeviceFlash.parse(recalibratedDoc()),
      );

      expect(rig.channelCells[0]?.sensitivityMvV, closeTo(1.9985, 1e-12));
    });
  });

  group('pending edits', () {
    test(
      'edits take effect immediately; revert restores the flash state',
      () async {
        final rig = await newRig();
        rig.onFlashRead('dev1', 'Bench unit', fixture());

        rig.setSlot(
          3,
          LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
        );
        expect(rig.hasPending, isTrue);
        expect(rig.channelTitles[3], 'New');
        expect(rig.history, hasLength(5)); // typed-in values are remembered

        rig.revert();
        expect(rig.hasPending, isFalse);
        expect(rig.channelTitles[3], 'CH 4');
      },
    );

    test(
      'swap exchanges slots (assign/unassign across the boundary)',
      () async {
        final rig = await newRig();
        rig.onFlashRead('dev1', 'Bench unit', fixture());

        // Drag the spare (slot 4) onto CH2 (slot 1): the two exchange.
        rig.swapSlots(4, 1);
        expect(rig.channelTitles[1], 'Spare 50');
        expect(rig.effectiveSlots.cellAt(4)?.name, 'Break jig');

        // Drag 'Spare 50' (now on CH2) onto the empty CH4: a move — the
        // channel it left goes empty, the evicted 'Break jig' stays put.
        rig.swapSlots(1, 3);
        expect(rig.channelTitles[1], 'CH 2');
        expect(rig.effectiveSlots[1], isNull);
        expect(rig.channelTitles[3], 'Spare 50');
        expect(rig.effectiveSlots.cellAt(4)?.name, 'Break jig');

        // Self-swap is a no-op.
        rig.swapSlots(3, 3);
        expect(rig.channelTitles[3], 'Spare 50');
      },
    );

    test(
      'pending survives a disconnect+reconnect to the same device',
      () async {
        final rig = await newRig();
        rig.onFlashRead('dev1', 'Bench unit', fixture());
        rig.setSlot(
          3,
          LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
        );

        // Reconnect: the device re-reads with unchanged content — fresh
        // mtimes (a pure rewrite elsewhere) do NOT count as a change.
        rig.onFlashRead(
          'dev1',
          'Bench unit',
          DeviceFlash.parse(
            demoBoardCalibrationDoc.replaceFirst(
              '2026-07-20T10:15:00.000Z',
              '2026-07-21T08:00:00.000Z',
            ),
          ),
        );
        expect(rig.hasPending, isTrue);
        expect(rig.channelTitles[3], 'New');
      },
    );

    test('pending is discarded when the device changed while away', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.setSlot(
        3,
        LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
      );

      rig.onFlashRead(
        'dev1',
        'Bench unit',
        DeviceFlash.parse(recalibratedDoc()),
      );
      expect(rig.hasPending, isFalse);
      expect(rig.channelTitles[3], 'CH 4'); // edited slot is gone
    });

    test('pending for another device is discarded on connect', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.setSlot(
        3,
        LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
      );

      rig.onFlashRead('dev2', 'Other unit', fixture());
      expect(rig.hasPending, isFalse);
    });
  });

  group('save to device', () {
    test(
      'writes edited slots with fresh mtimes and verbatim board keys',
      () async {
        final rig = await newRig();
        rig.onFlashRead('dev1', 'Bench unit', fixture());
        rig.setSlot(
          3,
          LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
        );

        expect(await rig.saveToDevice(), isTrue);
        expect(rig.hasPending, isFalse);
        expect(rig.channelTitles[3], 'New'); // saved state stays effective

        final written = DeviceFlash.parse(transport.lastWrittenDoc!);
        expect(written.slots.cellAt(3)?.name, 'New');
        expect(
          written.slots[3] != null && written.slots[3]!.mtime != null,
          isTrue,
        );
        // Board keys round-trip byte-identical in content.
        expect(
          written.board.channels[0].readings,
          fixture().board.channels[0].readings,
        );
        expect(written.board.factoryDate, '2026-07-20');
      },
    );

    test('a failed write keeps the pending edits', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.setSlot(
        3,
        LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
      );
      transport.failWrite = true;

      expect(await rig.saveToDevice(), isFalse);
      expect(rig.hasPending, isTrue);
      expect(rig.channelTitles[3], 'New');
    });

    test('refuses to write while a different device is connected', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.setSlot(
        3,
        LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
      );
      // The pending edits belong to dev1, but dev2 is on the link now:
      // writing would stamp dev1's factory board keys onto dev2's flash.
      transport.deviceId = 'dev2';

      expect(await rig.saveToDevice(), isFalse);
      expect(transport.lastWrittenDoc, isNull); // nothing was sent
      expect(rig.hasPending, isTrue);
      expect(rig.channelTitles[3], 'New');
    });

    test('a read-back mismatch fails the save and keeps the edits', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.setSlot(
        3,
        LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
      );
      // The device silently ignored the write: it serves the OLD document.
      transport.readBackDoc = demoBoardCalibrationDoc;

      expect(await rig.saveToDevice(), isFalse);
      expect(rig.hasPending, isTrue);
      expect(rig.channelTitles[3], 'New');
      // The flash truth was NOT advanced to the unverified write.
      expect(rig.pending?.edited.cellAt(3)?.name, 'New');
    });

    test('an edit landing mid-write is kept, not silently discarded', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.setSlot(
        3,
        LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
      );

      transport.writeGate = Completer<void>();
      final saveFuture = rig.saveToDevice();
      // The save has snapshotted its document; this edit lands in the same
      // pending session while the write is in flight.
      rig.setSlot(
        4,
        LoadCellProfile(name: 'Other', capacityKg: 10, sensitivityMvV: 2),
      );
      transport.writeGate!.complete();

      // The save refuses to commit: the pending session moved under it.
      expect(await saveFuture, isFalse);
      expect(rig.hasPending, isTrue);
      expect(rig.channelTitles[3], 'New');
      expect(rig.effectiveSlots.cellAt(4)?.name, 'Other');
      // The flash truth was not advanced past the real read.
      expect(rig.pending?.edited.cellAt(4)?.name, 'Other');
    });

    test('unknown flash keys ride through the save verbatim', () async {
      final rig = await newRig();
      const withExtras =
          'K3CAL1\n'
          'cal.date=2026-07-20\n'
          'hw.rev=3\n'
          'future.tooling=keep me\n'
          'END\n';
      rig.onFlashRead('dev1', 'Bench unit', DeviceFlash.parse(withExtras));
      rig.setSlot(
        3,
        LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
      );

      expect(await rig.saveToDevice(), isTrue);
      expect(transport.lastWrittenDoc, contains('hw.rev=3'));
      expect(transport.lastWrittenDoc, contains('future.tooling=keep me'));
    });
  });

  group('history ordering', () {
    test(
      'batch-seen cells keep first-seen (slot) order across re-reads',
      () async {
        final rig = await newRig();
        rig.onFlashRead('dev1', 'Bench unit', fixture());
        final firstOrder = rig.history.map((e) => e.cell).toList();
        expect(firstOrder.map((c) => c.name), [
          'Thrust cell',
          'Break jig',
          '',
          'Spare 50',
        ]);

        // Add a typed-in cell so the list has a non-tie member too.
        final typed = LoadCellProfile(
          name: 'New',
          capacityKg: 50,
          sensitivityMvV: 1,
        );
        rig.setSlot(3, typed);
        expect(rig.history, hasLength(5));

        // Re-reads re-stamp every fixture cell with one shared `now`. The
        // tie group must keep its original slot order, deterministically,
        // and repeated re-reads must not churn it (Dart's List.sort is
        // unstable — see RigState._sortHistory). The typed cell's absolute
        // position depends on the wall clock's resolution (adjacent nows may
        // tie), so assert the fixture cells' RELATIVE order.
        for (var i = 0; i < 3; ++i) {
          rig.onFlashRead('dev1', 'Bench unit', fixture());
          expect(
            rig.history.map((e) => e.cell).where((c) => c != typed),
            firstOrder,
          );
        }
        // Value-equal cells upsert in place — re-reads never duplicate.
        expect(rig.history, hasLength(5));
      },
    );
  });

  group('history persistence', () {
    test(
      'history survives a restart (new RigState on the same prefs)',
      () async {
        final rig = await newRig();
        rig.onFlashRead('dev1', 'Bench unit', fixture());
        expect(rig.history, hasLength(4));

        final rig2 = await newRig();
        expect(rig2.history, hasLength(4));
        expect(rig2.history.map((e) => e.cell.name), contains('Thrust cell'));
      },
    );

    test('a malformed history entry is dropped, the rest survives', () async {
      SharedPreferences.setMockInitialValues({
        'rig_history':
            '[{"cell":{"name":"Good","capacityKg":100,"sensitivityMvV":2},'
            '"lastSeen":1753000000000,"deviceName":"d","origin":"device"},'
            '{"bogus":true}]',
      });
      final rig = await newRig();
      expect(rig.history, hasLength(1));
      expect(rig.history.single.cell.name, 'Good');
    });
  });
}
