import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/rig_state.dart';

/// Tests for [RigState]: flash reads, pending edits (restore/discard across
/// reconnects), save/revert, history, and change detection. Transport is a
/// fake capturing the written document; SharedPreferences is mocked.
class _FakeTransport implements RigFlashTransport {
  String deviceId = 'dev1';
  String deviceName = 'Bench unit';
  String? lastWrittenDoc;
  bool failWrite = false;

  @override
  String get connectedDeviceId => deviceId;

  @override
  String get connectedDeviceName => deviceName;

  @override
  Future<void> writeFlashDoc(String doc) async {
    if (failWrite) throw StateError('write failed');
    lastWrittenDoc = doc;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeTransport transport;
  late AppEvents events;
  late List<AppEvent> seen;

  Future<RigState> settledRig() async {
    final rig = RigState(transport: transport, events: events);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return rig;
  }

  DeviceFlash fixture() => DeviceFlash.parse(demoBoardCalibrationDoc);

  /// The fixture doc with a recalibrated CH1 cell (span bumped).
  String recalibratedDoc() => demoBoardCalibrationDoc.replaceFirst(
    'lc0.span=1.00037',
    'lc0.span=1.00099',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    transport = _FakeTransport();
    events = AppEvents();
    seen = [];
    events.stream.listen(seen.add);
  });

  group('flash reads', () {
    test('first read populates slots, titles and history; no event', () async {
      final rig = await settledRig();
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
      expect(seen, isEmpty);
    });

    test('an identical re-read is quiet', () async {
      final rig = await settledRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      expect(seen, isEmpty);
    });

    test('a changed device wins and raises the FYI event', () async {
      final rig = await settledRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        DeviceFlash.parse(recalibratedDoc()),
      );
      await pumpEventQueue(); // AppEvents delivers asynchronously

      final notices = seen.whereType<RigChangedSinceLastVisit>();
      expect(notices, hasLength(1));
      expect(notices.single.changes.single, contains('CH1'));
      expect(notices.single.changes.single, contains('Thrust cell'));
      // The device is the truth: readings use the new values immediately.
      expect(rig.channelCells[0]?.span, closeTo(1.00099, 1e-12));
    });
  });

  group('pending edits', () {
    test(
      'edits take effect immediately; revert restores the flash state',
      () async {
        final rig = await settledRig();
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
        final rig = await settledRig();
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
        final rig = await settledRig();
        rig.onFlashRead('dev1', 'Bench unit', fixture());
        rig.setSlot(
          3,
          LoadCellProfile(name: 'New', capacityKg: 50, sensitivityMvV: 1),
        );

        // Reconnect: the device re-reads with unchanged content.
        rig.onFlashRead('dev1', 'Bench unit', fixture());
        expect(rig.hasPending, isTrue);
        expect(rig.channelTitles[3], 'New');
        expect(seen, isEmpty); // no FYI: nothing changed on the device
      },
    );

    test('pending is discarded when the device changed while away', () async {
      final rig = await settledRig();
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
      await pumpEventQueue();
      expect(rig.hasPending, isFalse);
      expect(rig.channelTitles[3], 'CH 4'); // edited slot is gone
      final notices = seen.whereType<RigChangedSinceLastVisit>();
      expect(
        notices.single.changes.where(
          (c) => c.contains('unsaved changes were discarded'),
        ),
        hasLength(1),
      );
    });

    test('pending for another device is discarded on connect', () async {
      final rig = await settledRig();
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
        final rig = await settledRig();
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

        // Our own write must not come back as a "changed elsewhere" notice on
        // the next connect (change detection was re-anchored).
        rig.onFlashRead('dev1', 'Bench unit', written);
        expect(seen.whereType<RigChangedSinceLastVisit>(), isEmpty);
      },
    );

    test('a failed write keeps the pending edits', () async {
      final rig = await settledRig();
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
  });

  group('history persistence', () {
    test(
      'history survives a restart (new RigState on the same prefs)',
      () async {
        final rig = await settledRig();
        rig.onFlashRead('dev1', 'Bench unit', fixture());
        expect(rig.history, hasLength(4));

        final rig2 = await settledRig();
        expect(rig2.history, hasLength(4));
        expect(rig2.history.map((e) => e.cell.name), contains('Thrust cell'));
      },
    );

    test('a change on a KNOWN device fires once, then re-anchors', () async {
      final rig = await settledRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        DeviceFlash.parse(recalibratedDoc()),
      );
      await pumpEventQueue();
      expect(seen.whereType<RigChangedSinceLastVisit>(), hasLength(1));

      // A third read of the same (new) content is quiet again.
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        DeviceFlash.parse(recalibratedDoc()),
      );
      await pumpEventQueue();
      expect(seen.whereType<RigChangedSinceLastVisit>(), hasLength(1));
    });
  });

  group('DMM excitation cross-check (per-device)', () {
    test('no flash doc: nowhere to hang the value, set is a no-op', () async {
      final rig = await settledRig();
      await rig.setMeasuredExcitationMv(4530.2);
      expect(rig.measuredExcitationMv, isNull);
    });

    test('the value attaches to the flash doc\'s device only', () async {
      final rig = await settledRig();
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      await rig.setMeasuredExcitationMv(4530.2);
      expect(rig.measuredExcitationMv, 4530.2);

      // Another device has no reading of its own…
      rig.onFlashRead('dev2', 'Other unit', fixture());
      expect(rig.measuredExcitationMv, isNull);

      // …and dev1's reading is still there when dev1 comes back.
      rig.onFlashRead('dev1', 'Bench unit', fixture());
      expect(rig.measuredExcitationMv, 4530.2);

      // Clearing works.
      await rig.setMeasuredExcitationMv(null);
      expect(rig.measuredExcitationMv, isNull);
    });

    test(
      'the value survives a restart (new RigState on the same prefs)',
      () async {
        final rig = await settledRig();
        rig.onFlashRead('dev1', 'Bench unit', fixture());
        await rig.setMeasuredExcitationMv(4530.2);

        final rig2 = await settledRig();
        expect(rig2.measuredExcitationMv, isNull); // no doc read yet
        rig2.onFlashRead('dev1', 'Bench unit', fixture());
        expect(rig2.measuredExcitationMv, 4530.2);
      },
    );
  });
}
