import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/segmentation_cmj.dart';
import 'package:dynamite_app/analysis/test_result.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/services/session_journal.dart';

void main() {
  const phases = CmjPhases(
    onset: 100,
    bwCross: 400,
    takeoff: 800,
    landing: 1200,
    end: 1800,
    sampleRate: 1000,
  );

  const result = TestResult(
    testId: 'cmj',
    person: 'Alex',
    bodyWeightKgf: 72.4,
    reps: [phases, phases],
  );

  group('TestResult JSON', () {
    test('round-trips every field', () {
      final decoded = TestResult.fromJson(
        jsonDecode(jsonEncode(result.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.testId, 'cmj');
      expect(decoded.person, 'Alex');
      expect(decoded.bodyWeightKgf, 72.4);
      expect(decoded.reps, hasLength(2));
      expect(decoded.reps.first.onset, 100);
      expect(decoded.reps.first.bwCross, 400);
      expect(decoded.reps.first.takeoff, 800);
      expect(decoded.reps.first.landing, 1200);
      expect(decoded.reps.first.end, 1800);
      expect(decoded.reps.first.sampleRate, 1000);
    });

    test('rejects out-of-order rep bounds', () {
      final json = result.toJson();
      (json['reps'] as List).first = {
        'onset': 500,
        'bwCross': 400,
        'takeoff': 800,
        'landing': 1200,
        'end': 1800,
        'sampleRate': 1000,
      };
      expect(() => TestResult.fromJson(json), throwsFormatException);
    });

    test('rejects a missing testId', () {
      final json = result.toJson()..remove('testId');
      expect(() => TestResult.fromJson(json), throwsFormatException);
    });
  });

  group('SessionEdit', () {
    test('carries the test result through the journal encoding', () {
      const meta = SessionMeta(
        name: 's',
        sampleRate: 1000,
        channelCount: 4,
        channelLabels: ['a', 'b', 'c', 'd'],
        tares: [null, null, null, null],
        calibration: [
          ChannelCalibration(board: null),
          ChannelCalibration(board: null),
          ChannelCalibration(board: null),
          ChannelCalibration(board: null),
        ],
        displayUnit: DisplayUnit.kgf,
        deviceInfo: {},
        recordedAt: '2026-01-01T00:00:00+00:00',
        ssnOrigin: 0,
        visibleChannels: [true, true, true, true],
      );
      const edit = SessionEdit(
        name: 's',
        notes: '',
        visibleChannels: [true, true, true, true],
        testResult: result,
      );
      final journal = parseSessionJournal(
        Uint8List.fromList([
          ...encodeSessionMeta(meta),
          ...encodeSessionEdit(edit),
        ]),
      );
      expect(journal.effectiveEdit.testResult?.testId, 'cmj');
      expect(journal.effectiveEdit.testResult?.reps, hasLength(2));
    });
  });
}
