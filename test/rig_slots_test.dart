import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'helpers/flash_docs.dart';

/// Tests for the rig-slot model and the flash document parse
/// ([DeviceFlash.parse] / [RigSlots.fromKv] / [RigSlots.toKv]), fed by the
/// same fixture the demo and mock devices serve.
void main() {
  group('DeviceFlash.parse (fixture doc)', () {
    final flash = flashFromDoc(
      demoBoardCalibrationDoc,
      pgaGains: const [1, 1, 1, 1],
    );
    final board = flash.board as ProvisionedBoardCalibration;

    test('board channels are factory-calibrated', () {
      expect(board.channels.where((c) => c.isCalibrated), hasLength(4));
      expect(board.calGroup!.date, '2026-07-20');
    });

    test('slots parse with names and exact sensitivities', () {
      final slots = flash.slots;
      expect(slots.cellAt(0)?.name, 'Thrust cell');
      expect(slots.cellAt(0)?.capacityKg, 200);
      expect(slots.cellAt(0)?.sensitivityMvV, closeTo(1.9993, 1e-12));

      expect(slots.cellAt(1)?.name, 'Break jig');
      expect(slots.cellAt(2)?.name, ''); // unnamed cell on CH 2
      expect(slots.cellAt(2)?.capacityKg, 100);
      expect(slots[3], isNull); // CH 3 empty
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
        'CH 2 · 100 kg · 2 mV/V',
        'CH 3',
      ]);
    });
  });

  group('RigSlots kv round-trip', () {
    test('toKv(fromKv(x)) reproduces the slots', () {
      final flash = flashFromDoc(
        demoBoardCalibrationDoc,
        pgaGains: const [1, 1, 1, 1],
      );
      final kv = flash.slots.toKv();
      // Integral values emit without a fraction: an unchanged rig diffs
      // clean against the fixture's factory-written values.
      expect(kv['lc0.cap'], '200');
      expect(kv['lc0.sens'], '1.9993');
      expect(kv['lc2.sens'], '2');

      final reparsed = RigSlots.fromKv(kv);
      for (int i = 0; i < kRigSlotCount; ++i) {
        expect(reparsed[i], flash.slots[i], reason: 'slot $i');
      }
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
      final kv = slots.toKv();
      expect(kv['lc0.name'], 'a=b c');
      expect(RigSlots.fromKv(kv).cellAt(0)?.name, 'a=b c');
    });

    test('unknown keys are ignored, never re-emitted', () {
      // Keys the model doesn't know (another tool's metadata) parse away;
      // the slots' kv map can only ever name slot keys.
      const withExtras =
          'hw.rev=3\nfuture.tooling=keep me\n'
          'lc0.cap=100\nlc0.sens=2';
      final flash = flashFromDoc(withExtras, pgaGains: const [1, 1, 1, 1]);
      expect(flash.slots.cellAt(0)?.capacityKg, 100);
      expect(flash.board, isA<UnprovisionedBoardCalibration>());
      expect(flash.slots.toKv().keys.every((k) => k.startsWith('lc')), isTrue);
    });
  });

  group('RigSlots lenient parse', () {
    test('a degenerate slot reads as empty, not as invalid flash', () {
      // The app owns the slot keys, so a bad state reads as "no cell": force
      // units report unavailable (visible), the raw values stay in the KVS
      // snapshot, and a save reconciles the device (see RigSlots.fromKv).
      for (final kv in [
        const {'lc0.cap': '-5', 'lc0.sens': '2'}, // non-positive cap
        const {'lc0.cap': '100'}, // sens missing
        const {'lc0.sens': 'abc'}, // unparseable sens
        const {'lc0.cap': 'NaN', 'lc0.sens': '2'}, // parses, not finite
        const {'lc0.name': 'orphaned name'}, // name without values
      ]) {
        final slots = RigSlots.fromKv(kv);
        expect(slots[0], isNull, reason: '$kv');
      }
      // The neighbouring slots are unaffected.
      final slots = RigSlots.fromKv({
        'lc0.sens': 'abc',
        'lc1.cap': '500',
        'lc1.sens': '2',
      });
      expect(slots[0], isNull);
      expect(slots.cellAt(1)?.capacityKg, 500);
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
