import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/channel_converter.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/load_cell.dart';

/// Tests for [ChannelConverter]: the calibration-bound conversion the whole
/// app converts through. The load-bearing invariants: the tare point maps
/// to exactly zero in every unit, availability agrees across the method
/// family, and the gross inverse round-trips (manual tare entry).
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
  const nominalLadder = <double>[10000, 10, 10, 10, 10, 10000];
  final sp = ladderSetpointsMvV(nominalLadder);
  final board = ChannelBoardCalibration(
    resistors: nominalLadder,
    readings: [for (final d in sp) alpha + beta * d],
    nominals: testNominals,
  );
  final nominalBoard = ChannelBoardCalibration(nominals: testNominals);
  final cell = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2);
  final assigned = ChannelConverter(
    ChannelCalibration(board: board, loadCell: cell),
    alpha,
  );
  final bare = ChannelConverter(ChannelCalibration(board: board), alpha);

  group('availability', () {
    test('electrical units convert without a cell; force units do not', () {
      for (final u in [DisplayUnit.mVv, DisplayUnit.mV, DisplayUnit.raw]) {
        expect(bare.converts(u), isTrue, reason: u.symbol);
        expect(bare.netMap(u), isNotNull, reason: u.symbol);
        expect(bare.grossMap(u), isNotNull, reason: u.symbol);
        expect(bare.diffMap(u), isNotNull, reason: u.symbol);
        expect(bare.countQuantum(u), isNotNull, reason: u.symbol);
      }
      for (final u in [
        DisplayUnit.kN,
        DisplayUnit.lbf,
        DisplayUnit.kgf,
        DisplayUnit.n,
      ]) {
        expect(bare.converts(u), isFalse, reason: u.symbol);
        expect(bare.netMap(u), isNull, reason: u.symbol);
        expect(bare.grossMap(u), isNull, reason: u.symbol);
        expect(bare.diffMap(u), isNull, reason: u.symbol);
        expect(bare.rawAtGross(u, 0), isNull, reason: u.symbol);
        expect(assigned.converts(u), isTrue, reason: u.symbol);
      }
    });

    test('no nominals: every unit but raw is unavailable', () {
      final noData = ChannelConverter(
        ChannelCalibration(board: ChannelBoardCalibration()),
        100,
      );
      for (final u in DisplayUnit.values) {
        if (u == DisplayUnit.raw) {
          expect(noData.converts(u), isTrue);
        } else {
          expect(noData.converts(u), isFalse, reason: u.symbol);
          expect(noData.netMap(u), isNull, reason: u.symbol);
        }
      }
    });
  });

  group('tare-zero invariant', () {
    test('the tare point converts to exactly zero in every unit', () {
      const tareRaw = 1.23e6;
      for (final cellAssigned in [true, false]) {
        final conv = ChannelConverter(
          ChannelCalibration(
            board: board,
            loadCell: cellAssigned ? cell : null,
          ),
          tareRaw,
        );
        for (final u in DisplayUnit.values) {
          if (!conv.converts(u)) continue;
          expect(conv.net(u, tareRaw), 0.0, reason: u.symbol);
        }
      }
    });

    test('the nominal chain reads exactly zero too', () {
      const tareRaw = -4.7e5;
      for (final cellAssigned in [true, false]) {
        final conv = ChannelConverter(
          ChannelCalibration(
            board: nominalBoard,
            loadCell: cellAssigned ? cell : null,
          ),
          tareRaw,
        );
        for (final u in DisplayUnit.values) {
          if (!conv.converts(u)) continue;
          expect(conv.net(u, tareRaw), 0.0, reason: u.symbol);
        }
      }
    });

    test('no tare: zero is the map zero point, not zero counts', () {
      final untaRed = ChannelConverter(
        ChannelCalibration(board: board, loadCell: cell),
        null,
      );
      expect(untaRed.net(DisplayUnit.mVv, 0)!.abs(), greaterThan(0));
      expect(untaRed.tareOffset(DisplayUnit.mVv), 0.0);
    });
  });

  group('net conversion', () {
    test('mV/V at a cal point is its setpoint minus the tare point', () {
      expect(
        assigned.net(DisplayUnit.mVv, board.readings![0]),
        closeTo(sp[0], 1e-9),
      );
    });

    test('raw is tare-subtracted counts', () {
      expect(
        assigned.net(DisplayUnit.raw, board.readings![0]),
        closeTo(board.readings![0] - alpha, 1e-9),
      );
    });

    test('mV follows mV/V via the nominal excitation', () {
      // The mV rung rests on the nominal chain: a calibrated board's mV/V
      // map is ratiometric (exact at the cal points), so mV differs from
      // mV/V by exactly the anchor excitation.
      expect(
        assigned.net(DisplayUnit.mV, board.readings![1]),
        closeTo(sp[1] * testNominals.excitationV, 1e-9),
      );
    });

    test('nominal mV matches the nominal chain multiplier', () {
      final nominal = ChannelConverter(
        ChannelCalibration(board: nominalBoard),
        0,
      );
      expect(
        nominal.net(DisplayUnit.mV, 1000),
        closeTo(1000 / testNominals.countsPerMvAtCellOutput, 1e-15),
      );
    });

    test('kgf scales mV/V by capacity/sensitivity; kN by 9.80665e-3', () {
      final rawValue = board.readings![0];
      final kgf = assigned.net(DisplayUnit.kgf, rawValue)!;
      expect(kgf, closeTo(sp[0] * 100, 1e-9)); // 200 kg / 2 mV/V
      expect(
        assigned.net(DisplayUnit.kN, rawValue),
        closeTo(kgf * 9.80665 / 1000, 1e-12),
      );
    });
  });

  group('gross / diff', () {
    test('gross differenced at the tare equals the net converter', () {
      final net = assigned.netMap(DisplayUnit.kgf)!;
      final gross = assigned.grossMap(DisplayUnit.kgf)!;
      for (final rawValue in [alpha, ...board.readings!]) {
        expect(gross(rawValue) - gross(alpha), closeTo(net(rawValue), 1e-9));
      }
    });

    test('raw gross is identity', () {
      expect(assigned.gross(DisplayUnit.raw, 1234), 1234);
    });

    test('tareOffset is the gross value at the tare point', () {
      expect(
        assigned.tareOffset(DisplayUnit.kgf),
        closeTo(assigned.gross(DisplayUnit.kgf, alpha)!, 1e-12),
      );
    });

    test('diff is counts over the end-point sensitivity', () {
      final diff = assigned.diffMap(DisplayUnit.mVv)!;
      expect(diff(1000), closeTo(1000 / board.sensitivityCountsPerMvV!, 1e-15));
    });

    test('kgf diff folds in the load cell', () {
      final diff = assigned.diffMap(DisplayUnit.kgf)!;
      expect(
        diff(1000),
        closeTo(1000 / board.sensitivityCountsPerMvV! * 100, 1e-12),
      );
    });
  });

  group('gross inverse (manual tare entry)', () {
    test('round-trips through the piecewise board map', () {
      final gross = assigned.grossMap(DisplayUnit.mVv)!;
      for (final rawValue in [alpha, ...board.readings!, -3e6]) {
        expect(
          assigned.rawAtGross(DisplayUnit.mVv, gross(rawValue)),
          closeTo(rawValue, 1e-6),
          reason: 'raw $rawValue',
        );
      }
    });

    test('folds in the load cell scale for force units', () {
      final rawValue = board.readings![0];
      expect(
        assigned.rawAtGross(
          DisplayUnit.kgf,
          assigned.gross(DisplayUnit.kgf, rawValue)!,
        ),
        closeTo(rawValue, 1e-6),
      );
    });

    test('nominal chain round-trips', () {
      final nominal = ChannelConverter(
        ChannelCalibration(board: nominalBoard),
        null,
      );
      expect(
        nominal.rawAtGross(
          DisplayUnit.mVv,
          nominal.gross(DisplayUnit.mVv, 1000)!,
        ),
        closeTo(1000, 1e-9),
      );
    });

    test('raw is identity', () {
      expect(assigned.rawAtGross(DisplayUnit.raw, 1234), 1234);
    });
  });
}
