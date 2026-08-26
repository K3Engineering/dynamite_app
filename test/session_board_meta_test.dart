import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_profile.dart';

/// SessionBoardMeta (board_calibration.dart): the board-level calibration
/// provenance frozen onto a recorded session — its JSON shape, its strict
/// inverse, and its projection from a live BoardCalibration.
void main() {
  const meta = SessionBoardMeta(
    factoryDate: '2026-01-15',
    calBoardId: 'cal-01',
    calTool: 'calibrate.py v3',
    calOrigin: 'factory',
    calTempsC: (dut: 23.1, calBoard: 22.8),
    calAdcGains: [1, 2, 4, 8],
    calDataInvalid: true,
    constantsStatus: BoardDataStatus.invalid,
    constantsDetail: 'missing afe_gain',
    provenance: {'adc_fsr': 'nominal', 'exc': 'factory'},
  );

  group('SessionBoardMeta JSON', () {
    test('round-trips every field', () {
      final back = SessionBoardMeta.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(meta.toJson()))),
      );
      expect(back.factoryDate, meta.factoryDate);
      expect(back.calBoardId, meta.calBoardId);
      expect(back.calTool, meta.calTool);
      expect(back.calOrigin, meta.calOrigin);
      expect(back.calTempsC, (
        dut: meta.calTempsC!.dut,
        calBoard: meta.calTempsC!.calBoard,
      ));
      expect(back.calAdcGains, meta.calAdcGains);
      expect(back.calDataInvalid, meta.calDataInvalid);
      expect(back.constantsStatus, meta.constantsStatus);
      expect(back.constantsDetail, meta.constantsDetail);
      expect(back.provenance, meta.provenance);
    });

    test(
      'null provenance fields stay absent in the JSON and parse as null',
      () {
        const bare = SessionBoardMeta(
          calDataInvalid: false,
          constantsStatus: BoardDataStatus.unprovisioned,
          constantsDetail: '',
          provenance: {},
        );
        final json = bare.toJson();
        expect(json.containsKey('cal_date'), isFalse);
        expect(json.containsKey('cal_temp'), isFalse);
        expect(json.containsKey('cal_adc'), isFalse);
        final back = SessionBoardMeta.fromJson(json);
        expect(back.factoryDate, isNull);
        expect(back.calTempsC, isNull);
        expect(back.calAdcGains, isNull);
      },
    );

    test('unknown keys are ignored', () {
      final json = meta.toJson()..['future_field'] = 42;
      expect(SessionBoardMeta.fromJson(json).calTool, meta.calTool);
    });

    test('a malformed constants_status is damage, not a guess', () {
      final json = meta.toJson()..['constants_status'] = 'maybe';
      expect(() => SessionBoardMeta.fromJson(json), throwsFormatException);
    });

    test('a missing constants_status is damage', () {
      final json = meta.toJson()..remove('constants_status');
      expect(() => SessionBoardMeta.fromJson(json), throwsFormatException);
    });

    test('a malformed cal_data_invalid is damage', () {
      final json = meta.toJson()..['cal_data_invalid'] = 'no';
      expect(() => SessionBoardMeta.fromJson(json), throwsFormatException);
    });

    test('a wrong-length cal_temp list is damage', () {
      final json = meta.toJson()..['cal_temp'] = [23.1];
      expect(() => SessionBoardMeta.fromJson(json), throwsFormatException);
    });

    test('a wrong-length cal_adc list is damage', () {
      final json = meta.toJson()..['cal_adc'] = [1.0, 2.0];
      expect(() => SessionBoardMeta.fromJson(json), throwsFormatException);
    });

    test('a non-map provenance is damage', () {
      final json = meta.toJson()..['provenance'] = 'nominal';
      expect(() => SessionBoardMeta.fromJson(json), throwsFormatException);
    });

    test('a non-string provenance value is damage', () {
      final json = meta.toJson()..['provenance'] = {'exc': 3};
      expect(() => SessionBoardMeta.fromJson(json), throwsFormatException);
    });
  });

  group('SessionBoardMeta.fromBoard', () {
    test('carries the board-level facts', () {
      final board = BoardCalibration(
        channels: [
          for (int i = 0; i < kAdcChannelCount; i++) ChannelBoardCalibration(),
        ],
        factoryDate: '2026-01-15',
        calTool: 'calibrate.py v3',
        calOrigin: 'field:jdoe',
        calTempsC: (dut: 30.0, calBoard: 25.0),
        calAdcGains: const [1, 1, 1, 1],
        calDataInvalid: true,
        nominals: BoardNominals(
          adcFsrV: 1.2,
          afeGain: 101,
          excitationV: 4.53,
          pgaGains: const [1, 1, 1, 1],
          provenance: const {'afe_gain': 'nominal'},
        ),
        constantsStatus: BoardDataStatus.invalid,
        constantsDetail: 'bad exc: "-"',
      );
      final meta = SessionBoardMeta.fromBoard(board);
      expect(meta.factoryDate, '2026-01-15');
      expect(meta.calTool, 'calibrate.py v3');
      expect(meta.calOrigin, 'field:jdoe');
      expect(meta.calTempsC, (dut: 30.0, calBoard: 25.0));
      expect(meta.calAdcGains, [1.0, 1.0, 1.0, 1.0]);
      expect(meta.calDataInvalid, isTrue);
      expect(meta.constantsStatus, BoardDataStatus.invalid);
      expect(meta.constantsDetail, 'bad exc: "-"');
      expect(meta.provenance, {'afe_gain': 'nominal'});
    });

    test('a board without resolved constants snapshots the verdict and an '
        'empty provenance', () {
      final board = BoardCalibration(
        channels: [
          for (int i = 0; i < kAdcChannelCount; i++) ChannelBoardCalibration(),
        ],
        constantsStatus: BoardDataStatus.unreadable,
      );
      final meta = SessionBoardMeta.fromBoard(board);
      expect(meta.constantsStatus, BoardDataStatus.unreadable);
      expect(meta.provenance, isEmpty);
      expect(meta.factoryDate, isNull);
    });
  });
}
