import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/metrics.dart';
import 'package:dynamite_app/analysis/segmentation_cmj.dart';
import 'package:dynamite_app/analysis/test_catalog.dart';
import 'package:dynamite_app/analysis/test_def.dart';
import 'package:dynamite_app/analysis/test_family.dart';
import 'package:dynamite_app/analysis/test_result.dart';
import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/derived_channel.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/models/graph_data_source.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/services/data_hub.dart';

import 'helpers/synthetic_plate.dart';

/// A stored result whose rep bounds can be pushed outside the recording, to
/// pin the loud-fail contract of [evaluateTestResult].
TestResult resultFor(List<TestRep> reps, {double bodyWeightKgf = 80}) =>
    TestResult(
      testId: jumpBatteryTest.id,
      person: 'Test',
      bodyWeightKgf: bodyWeightKgf,
      reps: reps,
    );

const _nominals = ChannelNominals(
  adcFsrV: 1.2,
  afeGain: 101,
  pgaGain: 1,
  excitationV: 4.53,
);

/// A real [DataHub] configured as a four-corner plate, fed scripted corner
/// kgf converted to raw counts — the same path a session's data takes, so the
/// analysis is re-run against a genuine [GraphDataSource].
DataHub sourceFromCorners(List<List<double>> corners) {
  final hub = DataHub()
    ..updateMathProfile(MathProfile.forcePlate(const [0, 1, 2, 3]))
    ..updateBoardCalibration(
      ProvisionedBoardCalibration(
        nominals: BoardNominals(
          adcFsrV: _nominals.adcFsrV,
          afeGain: _nominals.afeGain,
          excitationV: _nominals.excitationV,
          pgaGains: const [1, 1, 1, 1],
        ),
      ),
    )
    ..updateLoadCells([
      for (int i = 0; i < kAdcChannelCount; i++)
        // 200 kg at 2 mV/V: 1 kgf reads 0.01 mV/V.
        const LoadCellProfile(capacityKg: 200, sensitivityMvV: 2),
    ]);
  // counts = mV/V × countsPerMvV, and kgf → mV/V is ×2/200.
  final perKgf = _nominals.countsPerMvV * 2 / 200;
  final count = corners.first.length;
  for (int i = 0; i < count; i++) {
    final frame = List<int>.generate(
      kAdcChannelCount,
      (ch) => (corners[ch][i] * perKgf).round(),
    );
    hub.addSampleFrame(Int32List.fromList(frame));
  }
  return hub;
}

void main() {
  group('evaluateTestResult', () {
    // A scripted jump, persisted the way the runner writes it: the phases
    // become spans, and the result carries no metric values at all.
    late GraphDataSource source;
    late TestRep stored;

    setUpAll(() {
      final jump = SyntheticCmj();
      final window = jump.window;
      final seg = segmentCmj(
        window,
        const JumpContext(bwKgf: 80, sigmaKgf: 0.3),
      ) as CmjRep;
      source = sourceFromCorners(jump.cornerKgf);
      stored = TestRep(
        label: 'CMJ',
        start: seg.phases.onset,
        end: seg.phases.end,
        spans: seg.phases.spans,
      );
    });

    test('re-reads a stored jump from its spans alone', () {
      final reps = evaluateTestResult(
        resultFor([stored]),
        source,
        jumpBatteryTest,
      );
      expect(reps, hasLength(1));
      final rep = reps.single;
      expect(rep.eval.label, 'CMJ');
      expect(rep.eval.start, stored.start);
      expect(rep.eval.end, stored.end);
      // The metric values are recomputed, not carried: a definition change
      // applies to every old session.
      expect(rep.metric('height_flight'), greaterThan(0.05));
      expect(rep.spans, hasLength(stored.spans.length));
      // Overlays come from the family, so the session view needs no
      // per-family overlay code.
      expect(rep.overlays.spans, isNotEmpty);
    });

    test('a rep outside the recording fails the whole result', () {
      // One rep past the end: silently dropping it would leave a table whose
      // header count disagrees with its columns.
      final outside = TestRep(
        label: 'CMJ',
        start: stored.start,
        end: source.totalSamples + 10,
        spans: stored.spans,
      );
      expect(
        () => evaluateTestResult(
          resultFor([stored, outside]),
          source,
          jumpBatteryTest,
        ),
        throwsA(isA<TestResultUnreadable>()),
      );
    });

    test('a rep whose spans are not a jump fails loudly', () {
      const noPhases = TestRep(start: 0, end: 100);
      expect(
        () =>
            evaluateTestResult(resultFor([noPhases]), source, jumpBatteryTest),
        throwsA(isA<TestResultUnreadable>()),
      );
    });

    test('a session with no plate calibration fails loudly', () {
      expect(
        () =>
            evaluateTestResult(resultFor([stored]), DataHub(), jumpBatteryTest),
        throwsA(isA<TestResultUnreadable>()),
      );
    });
  });

  group('family tables', () {
    test('the jump table adds a mean column and an EUR row', () {
      final jump = SyntheticCmj();
      final window = jump.window;
      final cmj = segmentCmj(
        window,
        const JumpContext(bwKgf: 80, sigmaKgf: 0.3),
      ) as CmjRep;
      final cmjRep = buildCmjRep(
        window,
        cmj.phases,
        const CmjContext(bwKgf: 80),
        1,
      );

      final squatJump = SyntheticCmj(dip: false);
      final squat = segmentCmj(
        squatJump.window,
        const JumpContext(bwKgf: 80, sigmaKgf: 0.3),
      ) as CmjRep;
      final sjRep = buildCmjRep(
        squatJump.window,
        squat.phases,
        const CmjContext(bwKgf: 80),
        2,
      );

      final spec = opsFor(TestFamily.jump).table([cmjRep, sjRep]);
      expect(spec.metrics, cmjMetrics);
      expect(spec.reps, hasLength(2));
      expect(spec.columnLabels, ['Rep 1 (CMJ)', 'Rep 2 (SJ)']);
      expect(spec.trailing.map((t) => t.header), ['Mean']);
      // Both classes present: the EUR join is defined.
      expect(spec.extraRows.single.label, 'EUR (CMJ/SJ)');
      expect(spec.extraRows.single.values.last, isNotNull);
    });
  });
}
