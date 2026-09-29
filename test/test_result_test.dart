import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/test_result.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/services/session_journal.dart';

void main() {
  const rep = TestRep(
    label: 'cmj',
    start: 100,
    end: 1800,
    sampleRate: 1000,
    spans: [
      PhaseSpan(label: 'eccentric', start: 100, end: 400),
      PhaseSpan(label: 'concentric', start: 400, end: 801),
      PhaseSpan(label: 'flight', start: 801, end: 1200),
      PhaseSpan(label: 'landing', start: 1200, end: 1800),
    ],
  );

  const result = TestResult(
    testId: 'cmj',
    person: 'Alex',
    bodyWeightKgf: 72.4,
    reps: [rep, rep],
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
      final r = decoded.reps.first;
      expect(r.label, 'cmj');
      expect(r.start, 100);
      expect(r.end, 1800);
      expect(r.sampleRate, 1000);
      expect(r.spans, hasLength(4));
      expect(r.spans[0].label, 'eccentric');
      expect(r.spans[0].start, 100);
      expect(r.spans[1].start, 400);
      expect(r.spans[2].end, 1200);
    });

    test('a window-only rep (no label, no spans) round-trips', () {
      const windowOnly = TestRep(start: 2000, end: 32000, sampleRate: 1000);
      final decoded = TestRep.fromJson(windowOnly.toJson());
      expect(decoded.label, isNull);
      expect(decoded.spans, isEmpty);
    });

    test('rejects out-of-order span bounds', () {
      final json = result.toJson();
      (json['reps'] as List).first = {
        'start': 100,
        'end': 1800,
        'sampleRate': 1000,
        'spans': [
          {'label': 'eccentric', 'start': 400, 'end': 300},
        ],
      };
      expect(() => TestResult.fromJson(json), throwsFormatException);
    });

    test('rejects a span outside its window', () {
      final json = result.toJson();
      (json['reps'] as List).first = {
        'start': 100,
        'end': 1800,
        'sampleRate': 1000,
        'spans': [
          {'label': 'eccentric', 'start': 50, 'end': 400},
        ],
      };
      expect(() => TestResult.fromJson(json), throwsFormatException);
    });

    test('rejects a rep window with start >= end', () {
      final json = result.toJson();
      (json['reps'] as List).first = {
        'start': 1800,
        'end': 100,
        'sampleRate': 1000,
        'spans': const <Map<String, dynamic>>[],
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
