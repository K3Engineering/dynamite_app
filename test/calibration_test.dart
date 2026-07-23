import 'package:dynamite_app/models/calibration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ladderSetpointsMvV', () {
    test('nominal ladder produces symmetric datasheet setpoints', () {
      final sp = ladderSetpointsMvV(nominalLadderResistors);
      expect(sp.length, kCalPointCount);
      expect(sp[0], closeTo(40000 / 20040, 1e-12));
      expect(sp[1], closeTo(20000 / 20040, 1e-12));
      expect(sp[2], 0.0); // dead short: exact, resistor-independent
      expect(sp[3], closeTo(-sp[1], 1e-15));
      expect(sp[4], closeTo(-sp[0], 1e-15));
    });

    test('custom resistors shift the setpoints', () {
      const r = <double>[10001, 10.001, 9.999, 10.002, 9.998, 9999.5];
      final sp = ladderSetpointsMvV(r);
      const total = 20040.5;
      expect(
        sp[0],
        closeTo(1000 * (10.001 + 9.999 + 10.002 + 9.998) / total, 1e-12),
      );
      expect(sp[1], closeTo(1000 * (9.999 + 10.002) / total, 1e-12));
      expect(sp[2], 0.0);
    });
  });

  group('ChannelBoardCalibration (factory data)', () {
    const alpha = 412.7;
    const beta = 3198500.0;
    final sp = ladderSetpointsMvV(nominalLadderResistors);
    // A perfect affine device: raw = alpha + beta * setpoint.
    final affineReadings = [for (final d in sp) alpha + beta * d];

    test('piecewise map anchors exactly at every cal point', () {
      final cal = ChannelBoardCalibration(readings: affineReadings);
      for (int k = 0; k < kCalPointCount; ++k) {
        expect(cal.mvVFromRaw(affineReadings[k]), closeTo(sp[k], 1e-12));
      }
    });

    test('interpolates linearly between points', () {
      final cal = ChannelBoardCalibration(readings: affineReadings);
      final midRaw = (affineReadings[0] + affineReadings[1]) / 2;
      expect(cal.mvVFromRaw(midRaw), closeTo((sp[0] + sp[1]) / 2, 1e-12));
    });

    test('extrapolates along the outer segments', () {
      final cal = ChannelBoardCalibration(readings: affineReadings);
      final above = cal.mvVFromRaw(affineReadings[0] + 10000);
      expect(
        above,
        closeTo(
          sp[0] +
              10000 * (sp[0] - sp[1]) / (affineReadings[0] - affineReadings[1]),
          1e-9,
        ),
      );
      final below = cal.mvVFromRaw(affineReadings[4] - 10000);
      expect(
        below,
        closeTo(
          sp[4] -
              10000 * (sp[3] - sp[4]) / (affineReadings[3] - affineReadings[4]),
          1e-9,
        ),
      );
    });

    test('offset is the dead-short reading, span is the terminal slope', () {
      final cal = ChannelBoardCalibration(readings: affineReadings);
      expect(cal.offsetCounts, closeTo(alpha, 1e-9));
      expect(cal.spanCountsPerMvV, closeTo(beta, 1e-6));
      expect(
        cal.effectiveExcitationV,
        closeTo(beta / countsPerMvAtCellOutput, 1e-12),
      );
      expect(cal.terminalNonlinearityPpm(positiveSide: true), closeTo(0, 1e-9));
      expect(
        cal.terminalNonlinearityPpm(positiveSide: false),
        closeTo(0, 1e-9),
      );
    });

    test('piecewise map anchors bowed points; terminal NL reports the bow', () {
      final bowed = List<double>.of(affineReadings);
      bowed[1] += 100; // +mid reads 100 counts high
      final cal = ChannelBoardCalibration(readings: bowed);
      // The piecewise map still anchors every measured point exactly...
      for (int k = 0; k < kCalPointCount; ++k) {
        expect(cal.mvVFromRaw(bowed[k]), closeTo(sp[k], 1e-12));
      }
      // ...and the terminal nonlinearity is the bow over the +half span.
      final halfSpan = (bowed[0] - bowed[2]).abs();
      expect(
        cal.terminalNonlinearityPpm(positiveSide: true),
        closeTo(100 / halfSpan * 1e6, 1e-6),
      );
      expect(
        cal.terminalNonlinearityPpm(positiveSide: false),
        closeTo(0, 1e-9),
      );
    });
  });

  group('ChannelBoardCalibration (nominal fallback)', () {
    test('follows the nominal chain with zero offset', () {
      final cal = ChannelBoardCalibration();
      expect(cal.isFactoryCalibrated, isFalse);
      expect(cal.mvVFromRaw(1000), closeTo(1000 / nominalCountsPerMvV, 1e-18));
      expect(cal.mvVFromRaw(0), 0.0);
      expect(cal.offsetCounts, 0.0);
      expect(cal.spanCountsPerMvV, nominalCountsPerMvV);
      expect(cal.effectiveExcitationV, closeTo(nominalExcitationV, 1e-12));
      expect(cal.terminalNonlinearityPpm(positiveSide: true), 0.0);
    });
  });

  group('BoardCalibration.parse', () {
    const doc = '''
K3CAL1
cal.date=2026-07-20
cal.exc.mv=4530.24
ch0.r=10000.8,10.0012,9.9991,10.0008,10.0003,9999.4
ch0.raw=6399057.3,3200621.9,845.2,-3199374.1,-6397331.0
ch1.r=9999.2,9.9994,10.0006,10.0001,9.9997,10000.6
ch1.raw=6395113.8,3197911.4,-231.5,-3199688.2,-6399884.7
ch2.r=10000.1,10.0002,10.0004,9.9998,9.9996,9999.9
ch2.raw=6401205.6,3201448.2,1502.8,-3196441.9,-6394203.4
ch3.r=10000.4,10.0009,9.9996,10.0005,10.0002,10000.2
ch3.raw=6397822.1,3199541.0,64.9,-3198066.4,-6397555.7
END
''';

    test('full document parses every channel plus metadata', () {
      final board = BoardCalibration.parse(doc);
      expect(board.factoryDate, '2026-07-20');
      expect(board.excitationMv, closeTo(4530.24, 1e-9));
      for (final ch in board.channels) {
        expect(ch.isFactoryCalibrated, isTrue);
      }
      expect(board.channels[0].resistors[0], closeTo(10000.8, 1e-9));
      expect(board.channels[0].readings![2], closeTo(845.2, 1e-9));
      expect(board.channels[3].readings![0], closeTo(6397822.1, 1e-9));
      // Custom resistors flow into setpoints: ch0's +FS point follows its
      // own resistor values, not the nominal ladder.
      final sp0 = board.channels[0].setpoints[0];
      const r0 = <double>[10000.8, 10.0012, 9.9991, 10.0008, 10.0003, 9999.4];
      final expected =
          1000 *
          (r0[1] + r0[2] + r0[3] + r0[4]) /
          r0.fold<double>(0, (a, b) => a + b);
      expect(sp0, closeTo(expected, 1e-12));
    });

    test('missing or malformed keys degrade only the affected channel', () {
      final partial = BoardCalibration.parse('''
ch0.r=10000.8,10.0012,9.9991,10.0008,10.0003,9999.4
ch0.raw=6399057.3,3200621.9,845.2,-3199374.1,-6397331.0
ch1.r=9999.2,9.9994,10.0006,10.0001,9.9997
ch1.raw=6395113.8,3197911.4,-231.5,-3199688.2,-6399884.7
ch2.raw=6401205.6,3201448.2,1502.8,-3196441.9
''');
      expect(partial.channels[0].isFactoryCalibrated, isTrue);
      expect(partial.channels[0].resistors[0], closeTo(10000.8, 1e-9));
      // ch1: resistor list too short -> nominal resistors, readings kept.
      expect(partial.channels[1].isFactoryCalibrated, isTrue);
      expect(partial.channels[1].resistors, nominalLadderResistors);
      // ch2: readings too short -> uncalibrated.
      expect(partial.channels[2].isFactoryCalibrated, isFalse);
      // ch3: absent entirely -> uncalibrated.
      expect(partial.channels[3].isFactoryCalibrated, isFalse);
      expect(partial.factoryDate, isNull);
      expect(partial.excitationMv, isNull);
    });

    test('garbage and empty input yield an all-nominal board', () {
      for (final text in ['', 'not a calibration document', '===', 'x=y']) {
        final board = BoardCalibration.parse(text);
        expect(
          board.channels.every((c) => !c.isFactoryCalibrated),
          isTrue,
          reason: text,
        );
      }
    });

    test('duplicate readings are rejected as degenerate', () {
      final board = BoardCalibration.parse(
        'ch0.raw=100,100,100,100,100\n'
        'ch1.raw=6399057.3,3200621.9,845.2,-3199374.1,-6397331.0\n',
      );
      expect(board.channels[0].isFactoryCalibrated, isFalse);
      expect(board.channels[1].isFactoryCalibrated, isTrue);
    });

    test('serialize round-trips through parse', () {
      final original = BoardCalibration.parse(doc);
      final reparsed = BoardCalibration.parse(original.serialize());
      expect(reparsed.factoryDate, original.factoryDate);
      expect(reparsed.excitationMv, original.excitationMv);
      for (int i = 0; i < original.channels.length; ++i) {
        final a = original.channels[i];
        final b = reparsed.channels[i];
        for (int k = 0; k < kLadderResistorCount; ++k) {
          expect(b.resistors[k], closeTo(a.resistors[k], 1e-9));
        }
        for (int k = 0; k < kCalPointCount; ++k) {
          expect(b.readings![k], closeTo(a.readings![k], 1e-6));
        }
      }
    });
  });

  group('LoadCellProfile', () {
    test('kgf per mV/V folds in the span factor', () {
      final cell = LoadCellProfile(id: 'x', capacityKg: 200, sensitivityMvV: 2);
      expect(cell.kgfPerMvV, closeTo(100, 1e-12));
      cell.span = 1.01;
      expect(cell.kgfPerMvV, closeTo(101, 1e-12));
    });

    test('json round-trip', () {
      final cell = LoadCellProfile(
        id: 'lc1',
        name: 'Golden cell',
        capacityKg: 100,
        sensitivityMvV: 2.0123,
        serial: 'SN 1234',
        span: 0.9985,
      );
      final back = LoadCellProfile.fromJson(cell.toJson());
      expect(back.id, cell.id);
      expect(back.name, cell.name);
      expect(back.capacityKg, cell.capacityKg);
      expect(back.sensitivityMvV, cell.sensitivityMvV);
      expect(back.serial, cell.serial);
      expect(back.span, cell.span);
    });

    test('generic title renders from values, named title wins', () {
      final generic = LoadCellProfile(
        id: 'g',
        capacityKg: 200,
        sensitivityMvV: 2,
      );
      expect(generic.title, '200 kg · 2 mV/V');
      generic.name = 'Reference cell';
      expect(generic.title, 'Reference cell');
    });
  });

  group('ChannelCalibration', () {
    const alpha = 412.7;
    const beta = 3198500.0;
    final sp = ladderSetpointsMvV(nominalLadderResistors);
    final board = ChannelBoardCalibration(
      readings: [for (final d in sp) alpha + beta * d],
    );

    test('net values are map differences between raw and tare', () {
      final cal = ChannelCalibration(board: board);
      final rawFs = board.readings![0];
      expect(cal.netMvV(rawFs, alpha), closeTo(sp[0], 1e-9));
      expect(cal.netMvV(rawFs, rawFs), 0.0);
      expect(cal.netRaw(rawFs, alpha), closeTo(rawFs - alpha, 1e-9));
      expect(
        cal.netMv(rawFs, alpha),
        closeTo(sp[0] * board.effectiveExcitationV, 1e-9),
      );
    });

    test('force conversion needs an assigned load cell', () {
      final bare = ChannelCalibration(board: board);
      expect(bare.netKgf(board.readings![0], alpha), isNull);

      final cell = LoadCellProfile(id: 'c', capacityKg: 200, sensitivityMvV: 2);
      final assigned = ChannelCalibration(board: board, loadCell: cell);
      final rawFs = board.readings![0];
      expect(
        assigned.netKgf(rawFs, alpha),
        closeTo(sp[0] * 100, 1e-9), // 200 kg / 2 mV/V = 100 kgf per mV/V
      );
      cell.span = 1.02;
      expect(assigned.netKgf(rawFs, alpha), closeTo(sp[0] * 102, 1e-9));
    });

    test('local slope tracks the piecewise segment', () {
      final cal = ChannelCalibration(board: board);
      // Affine device: the local slope is beta everywhere.
      expect(cal.mvVPerCountAt(board.readings![1]), closeTo(1 / beta, 1e-15));
    });
  });
}
