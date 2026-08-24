import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/rig_flash_transport.dart';
import 'package:dynamite_app/services/rig_state.dart';

/// Tests for [RigState]: flash reads, pending edits (which die with the
/// link), save/revert, and history. Transport is a fake capturing the
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

  DeviceFlash fixture() =>
      DeviceFlash.parse(demoBoardCalibrationDoc, pgaGains: const [1, 1, 1, 1]);

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

    test(
      'a flash read without a device id violates the delivery contract',
      () async {
        final rig = await newRig();
        // Delivery is token-gated to a live link upstream, so an identity-
        // less document can never arrive — assert, don't silently ignore.
        expect(
          () => rig.onFlashRead('', '', fixture()),
          throwsA(isA<AssertionError>()),
        );
      },
    );

    test(
      'boardCalibration follows the current connection\'s document',
      () async {
        final rig = await newRig();

        // No flash document read yet.
        expect(rig.boardCalibration, isNull);

        rig.onFlashRead('dev1', 'Bench unit', fixture());
        expect(rig.boardCalibration, isNotNull);

        // The document dies with the link.
        rig.onLinkDropped();
        expect(rig.boardCalibration, isNull);
      },
    );

    test('a changed device wins: readings use the new values', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        DeviceFlash.parse(recalibratedDoc(), pgaGains: const [1, 1, 1, 1]),
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

    test('a link drop discards the document and pending edits', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.setSlot(
        3,
        LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
      );

      rig.onLinkDropped();
      expect(rig.hasDeviceDoc, isFalse);
      expect(rig.hasPending, isFalse);
      expect(rig.channelTitles[3], 'CH 4'); // no document: bare channels

      // The typed-in cell was recorded in history at edit time, so
      // re-entering it after a reconnect is a pick, not a re-type.
      expect(rig.history.map((e) => e.cell.name), contains('New'));

      // Reconnecting re-reads and starts clean.
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      expect(rig.hasPending, isFalse);
      expect(rig.channelTitles[3], 'CH 4');
    });
  });

  group('save to device', () {
    test('writes edited slots with verbatim board keys', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.setSlot(
        3,
        LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
      );

      expect(await rig.saveToDevice(), isTrue);
      expect(rig.hasPending, isFalse);
      expect(rig.channelTitles[3], 'New'); // saved state stays effective

      final written = DeviceFlash.parse(
        transport.lastWrittenDoc!,
        pgaGains: const [1, 1, 1, 1],
      );
      expect(written.slots.cellAt(3)?.name, 'New');
      // Board keys round-trip byte-identical in content.
      expect(
        written.board.channels[0].readings,
        fixture().board.channels[0].readings,
      );
      expect(written.board.factoryDate, '2026-07-20');
      // The commit keeps the read-time (PGA-resolved) board, not the
      // gain-less read-back's nominal one.
      expect(rig.boardCalibration, isNotNull);
      expect(
        rig.boardCalibration!.channels[0].readings,
        fixture().board.channels[0].readings,
      );
    });

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

    test('a link drop mid-save fails the save', () async {
      final rig = await newRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.setSlot(
        3,
        LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
      );

      transport.writeGate = Completer<void>();
      final saveFuture = rig.saveToDevice();
      // The link dies while the write is in flight: the document and the
      // pending session go with it, so the save must NOT commit.
      rig.onLinkDropped();
      transport.writeGate!.complete();

      expect(await saveFuture, isFalse);
      expect(rig.hasDeviceDoc, isFalse);
      expect(rig.hasPending, isFalse);
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
      expect(rig.effectiveSlots.cellAt(3)?.name, 'New');
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
    });

    test('unknown flash keys ride through the save verbatim', () async {
      final rig = await newRig();
      const withExtras =
          'K3CAL1\n'
          'cal.date=2026-07-20\n'
          'hw.rev=3\n'
          'future.tooling=keep me\n'
          'END\n';
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        DeviceFlash.parse(withExtras, pgaGains: const [1, 1, 1, 1]),
      );
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
