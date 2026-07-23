import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/models/force_unit.dart';

/// Tests for [ForceUnit]'s per-channel converters: availability (force units
/// need an assigned load cell), tare-netting through the board map, and the
/// terminal-slope diff converters used by the derivative graph.
void main() {
  // An affine "device": raw = 412.7 + 3198500 * setpoint.
  const alpha = 412.7;
  const beta = 3198500.0;
  final sp = ladderSetpointsMvV(nominalLadderResistors);
  final board = ChannelBoardCalibration(
    readings: [for (final d in sp) alpha + beta * d],
  );
  final nominalBoard = ChannelBoardCalibration();
  final cell = LoadCellProfile(id: 'c', capacityKg: 200, sensitivityMvV: 2);
  final assigned = ChannelCalibration(board: board, loadCell: cell);
  final bare = ChannelCalibration(board: board);

  group('availability', () {
    test(
      'electrical units convert without a load cell; force units do not',
      () {
        for (final u in [ForceUnit.mVv, ForceUnit.mV, ForceUnit.raw]) {
          expect(u.converterFor(bare, alpha), isNotNull, reason: u.symbol);
          expect(u.diffConverterFor(bare), isNotNull, reason: u.symbol);
        }
        for (final u in [
          ForceUnit.kN,
          ForceUnit.lbf,
          ForceUnit.kgf,
          ForceUnit.n,
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
      final conv = ForceUnit.mVv.converterFor(assigned, alpha)!;
      expect(conv(board.readings![0]), closeTo(sp[0], 1e-9));
      expect(conv(alpha), 0.0); // tare point maps to zero
    });

    test('raw is tare-subtracted counts', () {
      final conv = ForceUnit.raw.converterFor(assigned, alpha)!;
      expect(
        conv(board.readings![0]),
        closeTo(board.readings![0] - alpha, 1e-9),
      );
    });

    test('mV follows mV/V via the effective excitation', () {
      final mvV = ForceUnit.mVv.converterFor(assigned, alpha)!;
      final mv = ForceUnit.mV.converterFor(assigned, alpha)!;
      final raw = board.readings![1];
      expect(mv(raw), closeTo(mvV(raw) * board.effectiveExcitationV, 1e-9));
    });

    test('nominal mV matches the legacy fixed multiplier', () {
      final conv = ForceUnit.mV.converterFor(
        ChannelCalibration(board: nominalBoard),
        0,
      )!;
      expect(conv(1000), closeTo(1000 * rawToMvMultiplier, 1e-15));
    });

    test('kgf scales mV/V by capacity/sensitivity; kN by 9.80665e-3', () {
      final kgf = ForceUnit.kgf.converterFor(assigned, alpha)!;
      final kN = ForceUnit.kN.converterFor(assigned, alpha)!;
      final raw = board.readings![0];
      expect(kgf(raw), closeTo(sp[0] * 100, 1e-9)); // 200 kg / 2 mV/V
      expect(kN(raw), closeTo(kgf(raw) * 9.80665 / 1000, 1e-12));
    });
  });

  group('diff converters', () {
    test('mV/V diff is counts over the terminal span', () {
      final diff = ForceUnit.mVv.diffConverterFor(assigned)!;
      expect(diff(1000), closeTo(1000 / board.spanCountsPerMvV, 1e-15));
    });

    test('kgf diff folds in the load cell', () {
      final diff = ForceUnit.kgf.diffConverterFor(assigned)!;
      expect(diff(1000), closeTo(1000 / board.spanCountsPerMvV * 100, 1e-12));
    });
  });

  group('formatting', () {
    test('mV/V shows four decimals with an explicit sign', () {
      expect(ForceUnit.mVv.format(1.996), '+1.9960 mV/V');
      expect(ForceUnit.mVv.formatValueOnly(-0.5), '-0.5000');
      expect(ForceUnit.raw.format(12345), '+12345 Raw');
      expect(ForceUnit.kgf.format(1.5), '+1.500 kgf');
    });
  });
}
