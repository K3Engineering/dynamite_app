import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/models/display_unit.dart';

/// Tests for [DisplayUnit]'s per-channel converters: availability (force units
/// need an assigned load cell), tare-netting through the board map, and the
/// terminal-slope diff converters used by the derivative graph.
void main() {
  // An affine "device": raw = 412.7 + 3198500 * setpoint.
  const alpha = 412.7;
  const beta = 3198500.0;
  // Pro-like test chain, reproducing the app's former compiled constants.
  const testNominals = ChannelNominals(
    adcFsrV: 1.2,
    afeGain: 101,
    pgaGain: 1,
    excitationV: 4.53,
  );
  final sp = ladderSetpointsMvV(nominalLadderResistors);
  final board = ChannelBoardCalibration(
    readings: [for (final d in sp) alpha + beta * d],
    nominals: testNominals,
  );
  final nominalBoard = ChannelBoardCalibration(nominals: testNominals);
  final cell = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2);
  final assigned = ChannelCalibration(board: board, loadCell: cell);
  final bare = ChannelCalibration(board: board);

  group('effective', () {
    // The availability quadrants. (noBoard + cell) is meaningless — no
    // board constants resolve without a read — but the ladder must not care.
    const noBoard = (boardHasNominals: false, anyActiveHasLoadCell: false);
    const boardNoCell = (
      boardHasNominals: true,
      anyActiveHasLoadCell: false,
    );
    const boardAndCell = (boardHasNominals: true, anyActiveHasLoadCell: true);

    test('no board constants is raw, for every preference', () {
      for (final u in DisplayUnit.values) {
        expect(u.effective(noBoard), DisplayUnit.raw, reason: u.symbol);
        expect(
          u.effective((boardHasNominals: false, anyActiveHasLoadCell: true)),
          DisplayUnit.raw,
          reason: u.symbol,
        );
      }
    });

    test('force with no active load cell becomes mV/V', () {
      for (final u in [
        DisplayUnit.kN,
        DisplayUnit.lbf,
        DisplayUnit.kgf,
        DisplayUnit.n,
      ]) {
        expect(u.effective(boardNoCell), DisplayUnit.mVv, reason: u.symbol);
      }
    });

    test('force with a load cell stays', () {
      expect(DisplayUnit.kN.effective(boardAndCell), DisplayUnit.kN);
    });

    test('electrical preferences are not promoted', () {
      expect(DisplayUnit.mVv.effective(boardNoCell), DisplayUnit.mVv);
      expect(DisplayUnit.mV.effective(boardNoCell), DisplayUnit.mV);
      expect(DisplayUnit.raw.effective(boardNoCell), DisplayUnit.raw);
      expect(DisplayUnit.raw.effective(boardAndCell), DisplayUnit.raw);
    });

    test('isAvailable matches the effective ladder', () {
      expect(DisplayUnit.raw.isAvailable(noBoard), isTrue);
      expect(DisplayUnit.mVv.isAvailable(noBoard), isFalse);
      expect(DisplayUnit.mVv.isAvailable(boardNoCell), isTrue);
      expect(DisplayUnit.kN.isAvailable(boardNoCell), isFalse);
      expect(DisplayUnit.kN.isAvailable(boardAndCell), isTrue);
    });
  });

  group('availability', () {
    test(
      'electrical units convert without a load cell; force units do not',
      () {
        for (final u in [DisplayUnit.mVv, DisplayUnit.mV, DisplayUnit.raw]) {
          expect(u.converterFor(bare, alpha), isNotNull, reason: u.symbol);
          expect(u.diffConverterFor(bare), isNotNull, reason: u.symbol);
        }
        for (final u in [
          DisplayUnit.kN,
          DisplayUnit.lbf,
          DisplayUnit.kgf,
          DisplayUnit.n,
        ]) {
          expect(u.converterFor(bare, alpha), isNull, reason: u.symbol);
          expect(u.diffConverterFor(bare), isNull, reason: u.symbol);
          expect(u.converterFor(assigned, alpha), isNotNull, reason: u.symbol);
        }
      },
    );
  });

  group('converters net the tare through the board map', () {
    test('mV/V at a cal point is its setpoint minus the zero point', () {
      final conv = DisplayUnit.mVv.converterFor(assigned, alpha)!;
      expect(conv(board.readings![0]), closeTo(sp[0], 1e-9));
      expect(conv(alpha), 0.0); // tare point maps to zero
    });

    test('raw is tare-subtracted counts', () {
      final conv = DisplayUnit.raw.converterFor(assigned, alpha)!;
      expect(
        conv(board.readings![0]),
        closeTo(board.readings![0] - alpha, 1e-9),
      );
    });

    test('mV follows mV/V via the nominal excitation', () {
      final conv = DisplayUnit.mV.converterFor(assigned, alpha)!;
      // The mV rung rests on the nominal chain: a calibrated board's mV/V
      // map is ratiometric (exact at the cal points), so mV differs from
      // mV/V by exactly the nominal excitation.
      expect(
        conv(board.readings![1]),
        closeTo(sp[1] * testNominals.excitationV, 1e-9),
      );
    });

    test('nominal mV matches the nominal chain multiplier', () {
      final conv = DisplayUnit.mV.converterFor(
        ChannelCalibration(board: nominalBoard),
        0,
      )!;
      expect(
        conv(1000),
        closeTo(1000 / testNominals.countsPerMvAtCellOutput, 1e-15),
      );
    });

    test('no nominals: every unit but raw is unavailable', () {
      final noData = ChannelCalibration(board: ChannelBoardCalibration());
      for (final u in DisplayUnit.values) {
        if (u == DisplayUnit.raw) {
          expect(u.converterFor(noData, 0), isNotNull, reason: u.symbol);
        } else {
          expect(u.converterFor(noData, 0), isNull, reason: u.symbol);
          expect(u.diffConverterFor(noData), isNull, reason: u.symbol);
        }
      }
    });

    test('kgf scales mV/V by capacity/sensitivity; kN by 9.80665e-3', () {
      final kgf = DisplayUnit.kgf.converterFor(assigned, alpha)!;
      final kN = DisplayUnit.kN.converterFor(assigned, alpha)!;
      final raw = board.readings![0];
      expect(kgf(raw), closeTo(sp[0] * 100, 1e-9)); // 200 kg / 2 mV/V
      expect(kN(raw), closeTo(kgf(raw) * 9.80665 / 1000, 1e-12));
    });
  });

  group('diff converters', () {
    test('mV/V diff is counts over the end-point sensitivity', () {
      final diff = DisplayUnit.mVv.diffConverterFor(assigned)!;
      expect(diff(1000), closeTo(1000 / board.sensitivityCountsPerMvV!, 1e-15));
    });

    test('kgf diff folds in the load cell', () {
      final diff = DisplayUnit.kgf.diffConverterFor(assigned)!;
      expect(
        diff(1000),
        closeTo(1000 / board.sensitivityCountsPerMvV! * 100, 1e-12),
      );
    });
  });

  group('formatting', () {
    test('mV/V shows four decimals with an explicit sign', () {
      expect(DisplayUnit.mVv.format(1.996), '+1.9960 mV/V');
      expect(DisplayUnit.mVv.formatValueOnly(-0.5), '-0.5000');
      expect(DisplayUnit.raw.format(12345), '+12345 Raw');
      expect(DisplayUnit.kgf.format(1.5), '+1.500 kgf');
    });
  });

  group('axisRung', () {
    String sym(DisplayUnit u, double maxMag) => u.axisRung(maxMag).symbol;

    test('coarsest rung keeping scaled magnitudes >= 1', () {
      expect(sym(DisplayUnit.mV, 2), 'mV');
      expect(sym(DisplayUnit.mV, 0.4), 'µV'); // 400 µV
      expect(sym(DisplayUnit.mV, 4e-4), 'nV'); // 400 nV
      expect(sym(DisplayUnit.mVv, 0.02), 'µV/V');
      expect(sym(DisplayUnit.mVv, 2e-5), 'nV/V'); // 20 nV/V
      expect(sym(DisplayUnit.kgf, 2500), 'tf');
      expect(sym(DisplayUnit.kgf, 999), 'kgf');
      expect(sym(DisplayUnit.kgf, 0.5), 'gf'); // 500 gf
      expect(sym(DisplayUnit.n, 15000), 'kN');
      expect(sym(DisplayUnit.n, 5), 'N');
      expect(sym(DisplayUnit.n, 0.05), 'mN');
      expect(sym(DisplayUnit.kN, 2), 'kN');
      expect(sym(DisplayUnit.kN, 0.002), 'N'); // 2 N
      expect(sym(DisplayUnit.kN, 5e-4), 'mN'); // 500 mN
    });

    test('rung boundaries are inclusive at exactly 1', () {
      expect(sym(DisplayUnit.mV, 1), 'mV');
      expect(sym(DisplayUnit.mV, 1e-3), 'µV');
      expect(sym(DisplayUnit.kgf, 1000), 'tf');
      expect(sym(DisplayUnit.kgf, 1e-3), 'gf');
    });

    test('zero and sub-rung magnitudes clamp to the finest rung', () {
      expect(sym(DisplayUnit.mV, 0), 'nV');
      expect(sym(DisplayUnit.mV, 4e-7), 'nV'); // 0.4 nV
      expect(sym(DisplayUnit.kN, 4e-7), 'mN'); // 0.4 mN
    });

    test('single-rung units never scale', () {
      expect(sym(DisplayUnit.lbf, 0.031), 'lbf');
      expect(sym(DisplayUnit.lbf, 5000), 'lbf');
      expect(sym(DisplayUnit.raw, 0), 'Raw');
      expect(sym(DisplayUnit.raw, 8388608), 'Raw');
    });
  });

  group('axisDecimalsFor', () {
    test('resolves the 1/2/5 step exactly', () {
      expect(DisplayUnit.axisDecimalsFor(5), 0);
      expect(DisplayUnit.axisDecimalsFor(2), 0);
      expect(DisplayUnit.axisDecimalsFor(1000), 0);
      expect(DisplayUnit.axisDecimalsFor(0.5), 1);
      expect(DisplayUnit.axisDecimalsFor(0.2), 1);
      expect(DisplayUnit.axisDecimalsFor(0.05), 2);
      expect(DisplayUnit.axisDecimalsFor(0.02), 2);
      expect(DisplayUnit.axisDecimalsFor(0.001), 3);
      expect(DisplayUnit.axisDecimalsFor(5e-4), 4);
      expect(DisplayUnit.axisDecimalsFor(1e-7), 7);
    });

    test('is robust to floating-point noise near powers of ten', () {
      expect(DisplayUnit.axisDecimalsFor(1e3), 0);
      expect(DisplayUnit.axisDecimalsFor(1e-4 / 1e-6), 0); // ~100
      expect(DisplayUnit.axisDecimalsFor(1e-6 / 1e-3), 3); // ~0.001
    });
  });
}
