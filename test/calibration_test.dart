import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pro-like test chain, reproducing the app's former compiled constants
/// (101x AFE, PGA 1x, 4.53 V excitation, 1.2 V reference).
const testNominals = ChannelNominals(
  adcFsrV: 1.2,
  afeGain: 101,
  pgaGain: 1,
  excitationV: 4.53,
);

/// The nominal ladder values — an input to [ladderSetpointsMvV] for the
/// symmetric-datasheet case (the model no longer substitutes these for
/// missing hardware characterization).
const nominalLadder = <double>[10000, 10, 10, 10, 10, 10000];

/// The board-constant keys every parse below needs (the ladder keys are
/// ignored until the constants resolve).
const testConstantKeys =
    'adc_fsr=1.2,nominal\nexc=4.53,nominal\nafe_gain=101,nominal\n';
const testGains = <double>[1, 1, 1, 1];

void main() {
  group('ladderSetpointsMvV', () {
    test('nominal ladder produces symmetric datasheet setpoints', () {
      final sp = ladderSetpointsMvV(nominalLadder);
      expect(sp.length, kCalPointCount);
      expect(sp[0], closeTo(40000 / 20040, 1e-12));
      expect(sp[1], closeTo(20000 / 20040, 1e-12));
      expect(sp[2], 0.0); // dead short: exact, resistor-independent
      expect(sp[3], closeTo(-sp[1], 1e-15));
      expect(sp[4], closeTo(-sp[0], 1e-12));
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
    final sp = ladderSetpointsMvV(nominalLadder);
    // A perfect affine device: raw = alpha + beta * setpoint.
    final affineReadings = [for (final d in sp) alpha + beta * d];

    ChannelBoardCalibration affineChannel() => ChannelBoardCalibration(
      resistors: nominalLadder,
      readings: affineReadings,
      nominals: testNominals,
    );

    test('piecewise map anchors exactly at every cal point', () {
      final cal = affineChannel();
      for (int k = 0; k < kCalPointCount; ++k) {
        expect(cal.mvVFromRaw(affineReadings[k]), closeTo(sp[k], 1e-12));
      }
    });

    test('interpolates linearly between points', () {
      final cal = affineChannel();
      final midRaw = (affineReadings[0] + affineReadings[1]) / 2;
      expect(cal.mvVFromRaw(midRaw), closeTo((sp[0] + sp[1]) / 2, 1e-12));
    });

    test('extrapolates along the outer segments', () {
      final cal = affineChannel();
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

    test(
      'offset is the dead-short reading, sensitivity the end-point slope',
      () {
        final cal = affineChannel();
        expect(cal.offsetCounts, closeTo(alpha, 1e-9));
        expect(cal.sensitivityCountsPerMvV, closeTo(beta, 1e-6));
        // Zero offset is measured ÷ measured: no nominal chain involved.
        expect(cal.zeroOffsetUvV, closeTo(alpha / beta * 1000, 1e-9));
        expect(
          cal.sensitivityVsNominal,
          closeTo(beta / testNominals.countsPerMvV, 1e-12),
        );
      },
    );

    test('end-point deviations vanish for an affine device, report a bow', () {
      final cal = affineChannel();
      for (final d in cal.deviationsUvV!) {
        expect(d, closeTo(0, 1e-9));
      }
      final bowed = List<double>.of(affineReadings);
      bowed[1] += 100; // +mid reads 100 counts high
      final bowedCal = ChannelBoardCalibration(
        resistors: nominalLadder,
        readings: bowed,
        nominals: testNominals,
      );
      final deviations = bowedCal.deviationsUvV!;
      // The end-point chord is untouched by an interior bump, so only the
      // bowed point deviates: 100 counts expressed via the measured
      // sensitivity. The ±FS anchors are 0 by construction.
      final s = bowedCal.sensitivityCountsPerMvV!;
      const expectedCounts = [0.0, 100.0, 0.0, 0.0, 0.0];
      for (int k = 0; k < kCalPointCount; ++k) {
        expect(
          deviations[k],
          closeTo(expectedCounts[k] / s * 1000, 1e-9),
          reason: 'deviation $k',
        );
      }
      expect(ChannelBoardCalibration().deviationsUvV, isNull);
    });

    test('measured errors reference the nominal chain, nothing pinned', () {
      final cal = affineChannel();
      final errors = cal.measuredErrorsUvV!;
      for (int k = 0; k < kCalPointCount; ++k) {
        expect(
          errors[k],
          closeTo(
            (affineReadings[k] / testNominals.countsPerMvV - sp[k]) * 1000,
            1e-9,
          ),
          reason: 'error $k',
        );
      }
      // Unlike the end-point nonlinearity, no point is zero by
      // construction: the zero point carries the offset (alpha ≠ 0), the
      // ±FS points the gain error.
      expect(errors[kCalIdxZero], isNot(closeTo(0, 1e-9)));
      // An uncalibrated channel has neither figure.
      final bare = ChannelBoardCalibration(nominals: testNominals);
      expect(bare.measuredErrorsUvV, isNull);
      expect(bare.deviationsUvV, isNull);
    });

    test('piecewise map anchors bowed points; deviations report the bow', () {
      final bowed = List<double>.of(affineReadings);
      bowed[1] += 100; // +mid reads 100 counts high
      final cal = ChannelBoardCalibration(
        resistors: nominalLadder,
        readings: bowed,
        nominals: testNominals,
      );
      // The piecewise map still anchors every measured point exactly...
      for (int k = 0; k < kCalPointCount; ++k) {
        expect(cal.mvVFromRaw(bowed[k]), closeTo(sp[k], 1e-12));
      }
      // ...and the deviation at +mid is the bow via the measured
      // sensitivity; the other interior points sit on the chord.
      final s = cal.sensitivityCountsPerMvV!;
      expect(cal.deviationsUvV![1], closeTo(100 / s * 1000, 1e-9));
      expect(cal.deviationsUvV![2], closeTo(0, 1e-9));
      expect(cal.deviationsUvV![3], closeTo(0, 1e-9));
    });
  });

  group('ChannelBoardCalibration (nominal fallback)', () {
    test('follows the nominal chain with zero offset', () {
      final cal = ChannelBoardCalibration(nominals: testNominals);
      expect(cal.isFactoryCalibrated, isFalse);
      expect(
        cal.mvVFromRaw(1000),
        closeTo(1000 / testNominals.countsPerMvV, 1e-18),
      );
      expect(cal.mvVFromRaw(0), 0.0);
      expect(cal.offsetCounts, 0.0);
      expect(cal.sensitivityCountsPerMvV, testNominals.countsPerMvV);
      // No factory data: the correction diagnostics don't exist (the nominal
      // chain isn't a measurement, so there's nothing to report against it).
      expect(cal.sensitivityVsNominal, isNull);
      expect(cal.zeroOffsetUvV, isNull);
      expect(cal.deviationsUvV, isNull);
      expect(cal.measuredErrorsUvV, isNull);
    });
  });

  group('ChannelBoardCalibration (no nominals)', () {
    test('converts nothing: span and correction diagnostics are null', () {
      final cal = ChannelBoardCalibration();
      expect(cal.nominals, isNull);
      expect(cal.sensitivityCountsPerMvV, isNull);
      expect(cal.sensitivityVsNominal, isNull);
      expect(cal.zeroOffsetUvV, isNull);
      expect(cal.deviationsUvV, isNull);
      expect(cal.measuredErrorsUvV, isNull);
    });

    test('nominals survive the session-snapshot round trip', () {
      final cal = ChannelBoardCalibration(nominals: testNominals);
      final loaded = ChannelBoardCalibration.fromJson(cal.toJson());
      expect(loaded.nominals, isNotNull);
      expect(
        loaded.nominals!.countsPerMvV,
        closeTo(testNominals.countsPerMvV, 1e-12),
      );
      // A snapshot without nominals (an unprovisioned board) replays as
      // raw-only, never with guessed values.
      final bare = ChannelBoardCalibration.fromJson(
        ChannelBoardCalibration().toJson(),
      );
      expect(bare.nominals, isNull);
    });

    test('snapshot readings without nominals are rejected as damaged', () {
      // A pre-invariant snapshot could hold readings with no resolved
      // nominal chain; the strict parser refuses it rather than replaying
      // a partial instrument (the session boundary flags the damage).
      expect(
        () => ChannelBoardCalibration.fromJson({
          'r': nominalLadder,
          'raw': [1.0e6, 5.0e5, 0.0, -5.0e5, -1.0e6],
        }),
        throwsFormatException,
      );
      // So is a snapshot with one malformed half.
      expect(
        () => ChannelBoardCalibration.fromJson({
          'r': 'junk',
          'raw': [1.0e6, 5.0e5, 0.0, -5.0e5, -1.0e6],
          'n': testNominals.toJson(),
        }),
        throwsFormatException,
      );
      // And one with readings that could never have come from hardware.
      expect(
        () => ChannelBoardCalibration.fromJson({
          'r': nominalLadder,
          'raw': [1.0e9, 5.0e5, 0.0, -5.0e5, -1.0e6],
          'n': testNominals.toJson(),
        }),
        throwsFormatException,
      );
    });

    test('a valid snapshot round-trips the full correction', () {
      final cal = ChannelBoardCalibration(
        resistors: nominalLadder,
        readings: [6.4e6, 3.2e6, 845.2, -3.2e6, -6.4e6],
        nominals: testNominals,
      );
      final loaded = ChannelBoardCalibration.fromJson(cal.toJson());
      expect(loaded.isFactoryCalibrated, isTrue);
      expect(loaded.readings, cal.readings);
      expect(loaded.resistors, cal.resistors);
    });
  });

  group('resolveBoardConstants', () {
    const kv = {'adc_fsr': '1.2', 'exc': '4.53', 'afe_gain': '101'};

    test('all keys plus gains resolve ok, with per-channel chains', () {
      final r = resolveBoardConstants(kv, pgaGains: testGains);
      expect(r.status, BoardDataStatus.ok);
      expect(r.nominals, isNotNull);
      expect(r.nominals!.forChannel(2).countsPerMvV, testNominals.countsPerMvV);
    });

    test('provenance tags are stripped from values and kept', () {
      final r = resolveBoardConstants({
        'adc_fsr': '1.2,nominal',
        'exc': '4.53,dummycal',
        'afe_gain': '101',
      }, pgaGains: testGains);
      expect(r.status, BoardDataStatus.ok);
      expect(r.nominals!.excitationV, 4.53);
      expect(r.nominals!.provenance['exc'], 'dummycal');
      expect(r.nominals!.provenance.containsKey('afe_gain'), isFalse);
    });

    test('no keys at all is unprovisioned', () {
      final r = resolveBoardConstants(const {}, pgaGains: testGains);
      expect(r.status, BoardDataStatus.unprovisioned);
      expect(r.nominals, isNull);
    });

    test('a missing or bad key is invalid, naming the culprit', () {
      final missing = resolveBoardConstants({
        'adc_fsr': '1.2',
        'exc': '4.53',
      }, pgaGains: testGains);
      expect(missing.status, BoardDataStatus.invalid);
      expect(missing.detail, contains('afe_gain'));

      final bad = resolveBoardConstants({
        'adc_fsr': '1.2',
        'exc': 'soon',
        'afe_gain': '101',
      }, pgaGains: testGains);
      expect(bad.status, BoardDataStatus.invalid);
      expect(bad.detail, contains('exc'));
    });
  });

  group('BoardCalibration.parse', () {
    const doc =
        '''
K3CAL1
cal.date=2026-07-20
$testConstantKeys${''}ch0.r=10000.8,10.0012,9.9991,10.0008,10.0003,9999.4
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
      final board = BoardCalibration.parse(doc, pgaGains: testGains);
      expect(board.factoryDate, '2026-07-20');
      expect(board.isFactoryCalibrated, isTrue);
      expect(board.calDataInvalid, isFalse);
      expect(board.channels[0].resistors![0], closeTo(10000.8, 1e-9));
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

    test('board constants resolve into per-channel nominals', () {
      final board = BoardCalibration.parse(
        'adc_fsr=1.2,nominal\nexc=2.8,nominal\nafe_gain=1,nominal\n',
        pgaGains: const [32, 32, 32, 32],
      );
      expect(board.constantsStatus, BoardDataStatus.ok);
      final n = board.channels[0].nominals!;
      expect(n.adcFsrV, 1.2);
      expect(n.afeGain, 1);
      expect(n.pgaGain, 32);
      expect(n.excitationV, 2.8);
      expect(board.nominals!.provenance['exc'], 'nominal');
    });

    test('no calibration keys at all is an uncalibrated board, no warning', () {
      for (final text in ['', 'not a calibration document', '===', 'x=y']) {
        final board = BoardCalibration.parse(text, pgaGains: testGains);
        expect(board.isFactoryCalibrated, isFalse, reason: text);
        expect(board.calDataInvalid, isFalse, reason: text);
      }
    });

    test('a provisioned board without cal data adopts the nominal chain', () {
      final board = BoardCalibration.parse(
        testConstantKeys,
        pgaGains: testGains,
      );
      expect(board.constantsStatus, BoardDataStatus.ok);
      expect(board.nominals, isNotNull);
      expect(board.isFactoryCalibrated, isFalse);
      expect(board.calDataInvalid, isFalse);
    });
  });

  group('BoardCalibration.parse (all-or-nothing rejection)', () {
    /// ch0 + ch3 fully valid; the others carry one defect each.
    const validCh0 =
        'ch0.r=10000.8,10.0012,9.9991,10.0008,10.0003,9999.4\n'
        'ch0.raw=6399057.3,3200621.9,845.2,-3199374.1,-6397331.0\n';
    const validCh3 =
        'ch3.r=10000.4,10.0009,9.9996,10.0005,10.0002,10000.2\n'
        'ch3.raw=6397822.1,3199541.0,64.9,-3198066.4,-6397555.7\n';

    void expectWholeBoardRejected(String doc, String reason) {
      final board = BoardCalibration.parse(doc, pgaGains: testGains);
      expect(board.isFactoryCalibrated, isFalse, reason: reason);
      expect(board.calDataInvalid, isTrue, reason: reason);
      // The valid channel's data is NOT adopted: a partial instrument is
      // never presented.
      for (final ch in board.channels) {
        expect(ch.isFactoryCalibrated, isFalse, reason: '$reason (channel)');
      }
    }

    test('a malformed channel entry invalidates the whole board', () {
      // ch1: resistor list too short. ch2: readings too short.
      expectWholeBoardRejected(
        '$testConstantKeys$validCh0$validCh3'
            'ch1.r=9999.2,9.9994,10.0006,10.0001,9.9997\n'
            'ch1.raw=6395113.8,3197911.4,-231.5,-3199688.2,-6399884.7\n'
            'ch2.raw=6401205.6,3201448.2,1502.8,-3196441.9\n'
            'ch2.r=10000.1,10.0002,10.0004,9.9998,9.9996,9999.9\n',
        'malformed lists',
      );
    });

    test('unusable readings invalidate the whole board', () {
      // ch1: beyond the ADC's 24-bit bipolar range. ch2: a sub-thousand-count
      // gap — interpolation would divide by ~zero (a real ladder spread is
      // millions of counts).
      expectWholeBoardRejected(
        '$testConstantKeys$validCh0$validCh3'
            'ch1.r=9999.2,9.9994,10.0006,10.0001,9.9997,10000.6\n'
            'ch1.raw=9000000,3197911.4,-231.5,-3199688.2,-6399884.7\n'
            'ch2.r=10000.1,10.0002,10.0004,9.9998,9.9996,9999.9\n'
            'ch2.raw=6399057.3,6399057.4,1502.8,-3196441.9,-6394203.4\n',
        'unusable readings',
      );
    });

    test('duplicate readings are rejected as degenerate', () {
      expectWholeBoardRejected(
        '$testConstantKeys'
            'ch0.raw=100,100,100,100,100\n'
            'ch0.r=10000.8,10.0012,9.9991,10.0008,10.0003,9999.4\n'
            '$validCh3'
            'ch1.r=9999.2,9.9994,10.0006,10.0001,9.9997,10000.6\n'
            'ch1.raw=6395113.8,3197911.4,-231.5,-3199688.2,-6399884.7\n'
            'ch2.r=10000.1,10.0002,10.0004,9.9998,9.9996,9999.9\n'
            'ch2.raw=6401205.6,3201448.2,1502.8,-3196441.9,-6394203.4\n',
        'duplicate readings',
      );
    });

    test('non-positive resistors invalidate the whole board', () {
      expectWholeBoardRejected(
        '$testConstantKeys'
            'ch0.r=10000,10,10,0,10,10000\n'
            'ch0.raw=6399057.3,3200621.9,845.2,-3199374.1,-6397331.0\n',
        'non-positive resistors',
      );
    });

    test('a partially-written calibration is invalid flash, not a mix', () {
      // Only ch0 calibrated: the factory calibrates all channels in one
      // document, so a missing channel can only be failed flash.
      expectWholeBoardRejected(
        '$testConstantKeys$validCh0',
        'partial provisioning',
      );
    });

    test('calibration keys are ignored when the constants never resolved', () {
      // No board constants: the raw-only notice carries the board's state;
      // the cal keys would convert nothing, so they parse as absent (and
      // don't add a second warning).
      final board = BoardCalibration.parse(validCh0, pgaGains: testGains);
      expect(board.constantsStatus, BoardDataStatus.unprovisioned);
      expect(board.isFactoryCalibrated, isFalse);
      expect(board.calDataInvalid, isFalse);
    });
  });

  group('BoardCalibration cal metadata', () {
    const doc = '''
K3CAL1
cal.date=2026-08-08T01:35:40+00:00
cal.board=calboard-fw 1.2.1
cal.tool=board_calibration 1.0
cal.origin=factory
cal.temp=29.1,28.4
cal.adc=1,1,1,1
END
''';

    test('present keys parse; absent keys are null', () {
      final board = BoardCalibration.parse(doc, pgaGains: testGains);
      expect(board.calBoardId, 'calboard-fw 1.2.1');
      expect(board.calTool, 'board_calibration 1.0');
      expect(board.calOrigin, 'factory');
      expect(board.calTempsC!.dut, closeTo(29.1, 1e-12));
      expect(board.calTempsC!.calBoard, closeTo(28.4, 1e-12));
      expect(board.calAdcGains, [1.0, 1.0, 1.0, 1.0]);

      // A document from before these keys existed parses them as absent.
      final older = BoardCalibration.parse(
        'cal.date=2026-07-20\n',
        pgaGains: testGains,
      );
      expect(older.calBoardId, isNull);
      expect(older.calTool, isNull);
      expect(older.calOrigin, isNull);
      expect(older.calTempsC, isNull);
      expect(older.calAdcGains, isNull);
    });

    test('malformed values degrade to absent', () {
      final board = BoardCalibration.parse(
        'cal.temp=hot\ncal.adc=1,1\n',
        pgaGains: testGains,
      );
      expect(board.calTempsC, isNull);
      expect(board.calAdcGains, isNull);
    });

    test(
      'adcConfigDrifted compares cal-time gains to the runtime readback',
      () {
        final body = '$testConstantKeys${doc.split('K3CAL1\n').last}';
        final same = BoardCalibration.parse(body, pgaGains: const [1, 1, 1, 1]);
        expect(same.adcConfigDrifted, isFalse);
        final drifted = BoardCalibration.parse(
          body,
          pgaGains: const [32, 1, 1, 1],
        );
        expect(drifted.adcConfigDrifted, isTrue);
        // No cal.adc key: unknown, never a verdict.
        expect(
          BoardCalibration.parse(
            testConstantKeys,
            pgaGains: testGains,
          ).adcConfigDrifted,
          isNull,
        );
      },
    );

    test('the cal metadata keys round-trip through serialize', () {
      final flash = DeviceFlash.parse(doc, pgaGains: testGains);
      final reparsed = DeviceFlash.parse(
        flash.serialize(),
        pgaGains: testGains,
      );
      expect(reparsed.board.factoryDate, flash.board.factoryDate);
      expect(reparsed.board.calBoardId, flash.board.calBoardId);
      expect(reparsed.board.calTool, flash.board.calTool);
      expect(reparsed.board.calOrigin, flash.board.calOrigin);
      expect(reparsed.board.calTempsC?.dut, flash.board.calTempsC?.dut);
      expect(
        reparsed.board.calTempsC?.calBoard,
        flash.board.calTempsC?.calBoard,
      );
      expect(reparsed.board.calAdcGains, flash.board.calAdcGains);
      // And none of them leak into the verbatim-courier extraLines.
      expect(flash.extraLines, isEmpty);
    });
  });

  group('LoadCellProfile', () {
    test('kgf per mV/V is capacity over the exact sensitivity', () {
      final cell = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2);
      expect(cell.kgfPerMvV, closeTo(100, 1e-12));
      final cert = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2.02);
      expect(cert.kgfPerMvV, closeTo(200 / 2.02, 1e-12));
    });

    test('json round-trips; unknown keys are ignored', () {
      final cell = LoadCellProfile(
        name: 'Golden cell',
        capacityKg: 100,
        sensitivityMvV: 2.0123,
      );
      expect(LoadCellProfile.fromJson(cell.toJson()), cell);

      final withExtras = Map<String, dynamic>.from(cell.toJson())
        ..['serial'] = 'SN 1234';
      expect(LoadCellProfile.fromJson(withExtras), cell);
    });

    test('generic title renders from values, named title wins', () {
      final generic = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2);
      expect(generic.title, '200 kg · 2 mV/V');
      final named = generic.copyWith(name: 'Reference cell');
      expect(named.title, 'Reference cell');
    });

    test('values line lists the exact mV/V', () {
      final plain = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2);
      expect(plain.valuesLine, '200 kg · 2 mV/V');
      final cert = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2.007);
      expect(cert.valuesLine, '200 kg · 2.007 mV/V');
    });
  });
}
