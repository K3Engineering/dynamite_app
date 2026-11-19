import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/plate_series.dart';
import 'package:dynamite_app/analysis/test_catalog.dart';
import 'package:dynamite_app/analysis/test_def.dart';
import 'package:dynamite_app/runner/mold_flow.dart';

import 'helpers/synthetic_plate.dart';

/// One tick over scripted corner arrays, as the controller builds it.
MoldTick tickOf(
  List<List<double>> corners, {
  required int total,
  double bwKgf = 80,
  int nextNumber = 1,
}) => MoldTick(
  reader: PlateReader.fromCornerForce(
    (corner, index) => corners[corner][index],
    sampleRate: 1000,
  ),
  totalSamples: total,
  oldestSample: 0,
  bwKgf: bwKgf,
  sigmaKgf: 0.3,
  nextNumber: nextNumber,
);

void main() {
  group('RepCountFlow', () {
    test('a fresh flow is armed for stance-armed tests only', () {
      expect(
        RepCountFlow(jumpBatteryTest, jumpStyle: TestJumpStyle.auto).armed,
        isTrue,
      );
      // Unloaded arming waits for the plate to go quiet-empty first.
      expect(
        RepCountFlow(dropJumpTest, jumpStyle: TestJumpStyle.auto).armed,
        isFalse,
      );
    });

    test('a new recording starts from a clean state', () {
      // The structural claim: a flow is constructed at recording start, so a
      // previous run's rep start and stop target cannot survive into the next.
      final corners = <List<double>>[[], [], [], []];
      for (int i = 0; i < 3000; i++) {
        for (final c in corners) {
          c.add(80 / 4);
        }
      }
      final first = RepCountFlow(
        jumpBatteryTest,
        jumpStyle: TestJumpStyle.auto,
      );
      // Stand still long enough to see the stance; nothing to accept yet.
      final events = first.tick(tickOf(corners, total: 3000));
      expect(events.whereType<RepAccepted>(), isEmpty);
      expect(first.stopAfterSample, isNull);

      final second = RepCountFlow(
        jumpBatteryTest,
        jumpStyle: TestJumpStyle.auto,
      );
      expect(second.armed, isTrue);
      expect(second.stopAfterSample, isNull);
      expect(second.previewOverlays, isNull);
    });
  });

  group('TimedCaptureFlow', () {
    test('windows are contiguous and complete the mold', () {
      final sway = SyntheticSway(samples: 4000, copX: (_) => 0, copY: (_) => 0);
      final corners = sway.cornerLists();
      final flow = TimedCaptureFlow(rombergTest, startedAt: 0);
      final accepted = <RepAccepted>[];
      var completed = false;
      // Romberg's real windows are 30 s; tick a synthetic 1 s version instead
      // so the test stays fast, keeping the same window sequence shape.
      const shortTest = TestDef(
        id: 'romberg_short',
        name: 'Romberg (short)',
        category: 'Balance',
        description: '',
        mold: TestMold.timedCapture,
        family: TestFamily.sway,
        windows: [
          TestCaptureWindow(label: 'Eyes open', durationMs: 1000),
          TestCaptureWindow(label: 'Eyes closed', durationMs: 1000),
        ],
      );
      final shortFlow = TimedCaptureFlow(shortTest, startedAt: 0);
      for (int total = 100; total <= 4000; total += 100) {
        final events = shortFlow.tick(tickOf(corners, total: total));
        accepted.addAll(events.whereType<RepAccepted>());
        completed = completed || events.any((e) => e is MoldCompleted);
      }
      expect(completed, isTrue);
      expect(accepted, hasLength(2));
      expect(
        [for (final e in accepted) e.rep.eval.label],
        ['Eyes open', 'Eyes closed'],
      );
      // Contiguous, not overlapping.
      expect(accepted[0].rep.eval.end, accepted[1].rep.eval.start);
      expect(flow, isA<TimedCaptureFlow>());
    });
  });

  group('FreePassFlow', () {
    test('arms on the first unload after the stance, then counts passes', () {
      final walk = SyntheticGaitWalk();
      final corners = walk.cornerLists();
      final flow = FreePassFlow(gaitTest, startedAt: 0);
      var armed = false;
      final passes = <RepAccepted>[];
      for (int total = 100; total <= walk.sampleCount; total += 100) {
        final events = flow.tick(
          tickOf(corners, total: total, nextNumber: passes.length + 1),
        );
        armed = armed || events.any((e) => e is GaitArmed);
        passes.addAll(events.whereType<RepAccepted>());
      }
      expect(armed, isTrue);
      expect(passes, hasLength(2));
      for (final pass in passes) {
        expect(pass.rep.metric('contact_time'), closeTo(700, 60));
      }
    });
  });
}
