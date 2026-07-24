import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/services/demo_calibration.dart';

/// Tests for the rig-slot model and the full flash document
/// ([DeviceFlash] parse/serialize), fed by the same fixture the demo and
/// mock devices serve.
void main() {
  group('DeviceFlash.parse (fixture doc)', () {
    final flash = DeviceFlash.parse(demoBoardCalibrationDoc);

    test('board channels are factory-calibrated', () {
      expect(
        flash.board.channels.where((c) => c.isFactoryCalibrated),
        hasLength(4),
      );
      expect(flash.board.factoryDate, '2026-07-20');
    });

    test('slots parse with names, values, spans and mtimes', () {
      final slots = flash.slots;
      expect(slots.cellAt(0)?.name, 'Thrust cell');
      expect(slots.cellAt(0)?.capacityKg, 200);
      expect(slots.cellAt(0)?.span, closeTo(1.00037, 1e-12));
      expect(slots[0]?.mtime, isNotNull);

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
      final flash = DeviceFlash.parse(demoBoardCalibrationDoc);
      final reparsed = DeviceFlash.parse(flash.serialize());

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
      final boardOnly = DeviceFlash(
        board: BoardCalibration.parse(demoBoardCalibrationDoc),
        slots: RigSlots.empty(),
      );
      final reparsed = DeviceFlash.parse(boardOnly.serialize());
      expect(reparsed.slots.signatures, everyElement(isNull));
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
        board: BoardCalibration.nominal(),
        slots: slots,
      ).serialize();
      expect(doc.contains('lc0.name=a=b c'), isTrue);
      expect(DeviceFlash.parse(doc).slots.cellAt(0)?.name, 'a=b c');
    });
  });

  group('RigSlots', () {
    test('degenerate slots degrade to empty; invalid span falls back', () {
      final slots = RigSlots.fromKv(const {
        'lc0.cap': '-5', // non-positive: empty
        'lc0.sens': '2',
        'lc1.cap': '100',
        // sens missing: empty
        'lc2.cap': '100',
        'lc2.sens': '2',
        'lc2.span': 'banana', // invalid: falls back to 1.0
      });
      expect(slots[0], isNull);
      expect(slots[1], isNull);
      expect(slots.cellAt(2)?.span, 1.0);
    });

    test('withMove is remove-then-insert', () {
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
      final moved = fill().withMove(0, 2);
      expect(
        [for (int i = 0; i < 4; ++i) moved.cellAt(i)?.name],
        ['c1', 'c2', 'c0', 'c3'],
      );
      final back = moved.withMove(2, 0);
      expect(back, fill());
    });

    test('signatures track content and ignore mtime', () {
      final cell = LoadCellProfile(
        name: 'A',
        capacityKg: 100,
        sensitivityMvV: 2,
      );
      final a = RigSlots.empty().withSlot(0, RigSlot(cell: cell));
      final b = RigSlots.empty().withSlot(
        0,
        RigSlot(cell: cell, mtime: DateTime.utc(2026, 1, 1)),
      );
      expect(a.signatures, b.signatures);

      final c = b.withSlot(0, RigSlot(cell: cell.copyWith(span: 1.01)));
      expect(c.signatures, isNot(b.signatures));
    });
  });
}
