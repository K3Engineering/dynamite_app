import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/services/demo_calibration.dart';

/// Tests for the rig-slot model and the full flash document
/// ([DeviceFlash] parse/serialize), fed by the same fixture the demo and
/// mock devices serve.
void main() {
  group('DeviceFlash.parse (fixture doc)', () {
    final flash = DeviceFlash.parse(
      demoBoardCalibrationDoc,
      pgaGains: const [1, 1, 1, 1],
    );

    test('board channels are factory-calibrated', () {
      expect(
        flash.board.channels.where((c) => c.isFactoryCalibrated),
        hasLength(4),
      );
      expect(flash.board.factoryDate, '2026-07-20');
    });

    test('slots parse with names and exact sensitivities', () {
      final slots = flash.slots;
      expect(slots.cellAt(0)?.name, 'Thrust cell');
      expect(slots.cellAt(0)?.capacityKg, 200);
      expect(slots.cellAt(0)?.sensitivityMvV, closeTo(1.9993, 1e-12));

      expect(slots.cellAt(1)?.name, 'Break jig');
      expect(slots.cellAt(2)?.name, ''); // unnamed cell on CH3
      expect(slots.cellAt(2)?.capacityKg, 100);
      expect(slots[3], isNull); // CH4 empty
      expect(slots.cellAt(4)?.name, 'Spare 50'); // a spare
      for (int i = 5; i < kRigSlotCount; ++i) {
        expect(slots[i], isNull, reason: 'slot $i empty');
      }
    });

    test('channel cells and titles come from the first four slots', () {
      final cells = flash.slots.channelCells;
      expect(cells[0]?.name, 'Thrust cell');
      expect(cells[3], isNull);
      expect(flash.slots.channelTitles, [
        'Thrust cell',
        'Break jig',
        '100 kg · 2 mV/V',
        'CH 4',
      ]);
    });
  });

  group('DeviceFlash round-trip', () {
    test('serialize(parse(x)) preserves board keys and slots', () {
      final flash = DeviceFlash.parse(
        demoBoardCalibrationDoc,
        pgaGains: const [1, 1, 1, 1],
      );
      final reparsed = DeviceFlash.parse(
        flash.serialize(),
        pgaGains: const [1, 1, 1, 1],
      );

      expect(reparsed.board.factoryDate, flash.board.factoryDate);
      expect(reparsed.board.excitationMv, flash.board.excitationMv);
      for (int i = 0; i < 4; ++i) {
        expect(
          reparsed.board.channels[i].readings,
          flash.board.channels[i].readings,
        );
      }
      for (int i = 0; i < kRigSlotCount; ++i) {
        expect(reparsed.slots[i], flash.slots[i], reason: 'slot $i');
      }
    });

    test('a board-only document yields empty slots', () {
      // extraLines (the board-constant keys' courier) ride along, as in the
      // real save path — without them the serialized document loses the
      // constants and its calibration keys no longer resolve.
      final parsed = DeviceFlash.parse(
        demoBoardCalibrationDoc,
        pgaGains: const [1, 1, 1, 1],
      );
      final boardOnly = DeviceFlash(
        board: parsed.board,
        slots: RigSlots.empty(),
        extraLines: parsed.extraLines,
      );
      final reparsed = DeviceFlash.parse(
        boardOnly.serialize(),
        pgaGains: const [1, 1, 1, 1],
      );
      for (int i = 0; i < kRigSlotCount; ++i) {
        expect(reparsed.slots[i], isNull, reason: 'slot $i');
      }
      // And the board keys survive untouched.
      expect(reparsed.board.channels[0].isFactoryCalibrated, isTrue);
    });

    test('names flatten newlines and survive an equals sign', () {
      final slots = RigSlots.empty().withSlot(
        0,
        RigSlot(
          cell: LoadCellProfile(
            name: 'a=b\nc',
            capacityKg: 100,
            sensitivityMvV: 2,
          ),
        ),
      );
      final doc = DeviceFlash(
        board: DeviceFlash.parse(
          demoBoardCalibrationDoc,
          pgaGains: const [1, 1, 1, 1],
        ).board,
        slots: slots,
      ).serialize();
      expect(doc.contains('lc0.name=a=b c'), isTrue);
      expect(
        DeviceFlash.parse(
          doc,
          pgaGains: const [1, 1, 1, 1],
        ).slots.cellAt(0)?.name,
        'a=b c',
      );
    });

    test('unknown keys are preserved verbatim through parse + serialize', () {
      const withExtras =
          'K3CAL1\n'
          'cal.date=2026-07-20\n'
          'hw.rev=3\n'
          'future.tooling=keep me\n'
          'ch4.raw=1,2,3,4,5\n' // a future 8-channel device's key
          'lc0.cap=100\n'
          'lc0.sens=2\n'
          'END\n';
      final flash = DeviceFlash.parse(withExtras, pgaGains: const [1, 1, 1, 1]);
      expect(flash.extraLines, [
        'hw.rev=3',
        'future.tooling=keep me',
        'ch4.raw=1,2,3,4,5',
      ]);

      final roundTripped = DeviceFlash.parse(
        flash.serialize(),
        pgaGains: const [1, 1, 1, 1],
      );
      expect(roundTripped.extraLines, flash.extraLines);
      expect(roundTripped.slots.cellAt(0)?.capacityKg, 100);
      expect(roundTripped.board.factoryDate, '2026-07-20');
    });

    test('a blank-flash board does not get nominal resistors stamped', () {
      // No ch* keys in the source: serializing must not invent them —
      // nominal values written as 'chN.r' would pose as characterization.
      final flash = DeviceFlash.parse(
        'K3CAL1\nlc0.cap=100\nlc0.sens=2\nEND\n',
        pgaGains: const [1, 1, 1, 1],
      );
      final doc = flash.serialize();
      expect(doc.contains('ch'), isFalse, reason: doc);

      // Characterized values DO round-trip (the fixture's real board).
      final realDoc = DeviceFlash.parse(
        demoBoardCalibrationDoc,
        pgaGains: const [1, 1, 1, 1],
      ).serialize();
      expect(realDoc.contains('ch0.r='), isTrue);
      expect(realDoc.contains('ch3.raw='), isTrue);
    });
  });

  group('RigSlots', () {
    test('degenerate slots degrade to empty', () {
      final slots = RigSlots.fromKv(const {
        'lc0.cap': '-5', // non-positive: empty
        'lc0.sens': '2',
        'lc1.cap': '100',
        // sens missing: empty
        'lc2.cap': '100',
        'lc2.sens': '2',
      });
      expect(slots[0], isNull);
      expect(slots[1], isNull);
      expect(slots.cellAt(2)?.sensitivityMvV, 2);
    });

    test('withSwap exchanges two slots and nothing else', () {
      RigSlots fill() => RigSlots([
        for (int i = 0; i < kRigSlotCount; ++i)
          RigSlot(
            cell: LoadCellProfile(
              name: 'c$i',
              capacityKg: 100,
              sensitivityMvV: 2,
            ),
          ),
      ]);
      final swapped = fill().withSwap(0, 2);
      expect(
        [for (int i = 0; i < 4; ++i) swapped.cellAt(i)?.name],
        ['c2', 'c1', 'c0', 'c3'],
      );
      final back = swapped.withSwap(2, 0);
      expect(back, fill());
    });

    test('withSwap onto an empty slot is a move', () {
      final cell = LoadCellProfile(
        name: 'A',
        capacityKg: 100,
        sensitivityMvV: 2,
      );
      final slots = RigSlots.empty().withSlot(0, RigSlot(cell: cell));
      final moved = slots.withSwap(0, 5);
      expect(moved.cellAt(0), isNull);
      expect(moved.cellAt(5)?.name, 'A');
    });
  });
}
