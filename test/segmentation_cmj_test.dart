import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/events.dart';
import 'package:dynamite_app/analysis/plate_series.dart';
import 'package:dynamite_app/analysis/segmentation_cmj.dart';
import 'package:dynamite_app/analysis/test_result.dart';

import 'helpers/synthetic_plate.dart';

void main() {
  group('estimateBaseline', () {
    test('reads body weight and noise from quiet stance', () {
      final jump = SyntheticCmj();
      final window = PlateWindow.capture(jump.reader, 0, jump.quietEnd);
      final b = estimateBaseline(window, window.start, window.end)!;
      expect(b.meanKgf, closeTo(80, 0.1));
      expect(b.sigmaKgf, lessThan(0.05));
      expect(b.isUsable, isTrue);
    });
  });

  group('segmentCmj', () {
    test('finds a complete countermovement jump', () {
      final jump = SyntheticCmj();
      final window = jump.window;
      final baseline = estimateBaseline(window, 0, jump.quietEnd)!;
      final seg = segmentCmj(window, JumpContext.fromBaseline(baseline));
      expect(seg, isA<CmjRep>());
      final p = (seg as CmjRep).phases;
      expect(p.onset, lessThan(p.bwCross));
      expect(p.bwCross, lessThan(p.takeoff));
      expect(p.takeoff, lessThan(p.landing));
      expect(p.landing, lessThanOrEqualTo(p.end - 1));
      expect(
        p.flightSamples,
        closeTo(jump.flightEndIndex - jump.takeoffIndex, 30),
      );
      expect(seg.jumpClass, JumpClass.countermovement);
      expect(p.spans, hasLength(4));
    });

    test('pushing straight from quiet is a squat jump', () {
      final jump = SyntheticCmj(dip: false);
      final window = jump.window;
      final baseline = estimateBaseline(window, 0, jump.quietEnd)!;
      final seg = segmentCmj(window, JumpContext.fromBaseline(baseline));
      expect(seg, isA<CmjRep>());
      final rep = seg as CmjRep;
      expect(rep.jumpClass, JumpClass.squat);
      expect(rep.phases.eccentricSamples, 0);
      expect(rep.phases.spans, hasLength(3));
      expect(
        rep.phases.flightSamples,
        closeTo(jump.flightEndIndex - jump.takeoffIndex, 30),
      );
    });

    test('survives a 33 Hz plate ring', () {
      // A floppy plate rings hard at takeoff; the raw force crosses any
      // threshold many times per flight. Segmentation runs on the smoothed
      // envelope, so it must still find the jump.
      final jump = SyntheticCmj(ringAmplitudeKg: 5);
      final window = jump.window;
      final baseline = estimateBaseline(window, 0, jump.quietEnd)!;
      final seg = segmentCmj(window, JumpContext.fromBaseline(baseline));
      expect(seg, isA<CmjRep>());
      final p = (seg as CmjRep).phases;
      expect(
        p.flightSamples,
        closeTo(jump.flightEndIndex - jump.takeoffIndex, 30),
      );
    });

    test('quiet stance alone is no flight', () {
      final jump = SyntheticCmj();
      final window = PlateWindow.capture(jump.reader, 0, jump.quietEnd);
      final seg = segmentCmj(
        window,
        const JumpContext(bwKgf: 80, sigmaKgf: 0.002),
      );
      expect(seg, isA<CmjRejected>());
      expect((seg as CmjRejected).reason, CmjInvalidReason.noFlight);
    });

    test('an implausibly long airborne stretch is a step-off', () {
      final reader = PlateReader.fromCornerForce(
        (corner, index) => index < 1000 ? 20.0 : (index < 4000 ? 0.0 : 20.0),
        sampleRate: 1000,
      );
      final window = PlateWindow.capture(reader, 0, 5000);
      final seg = segmentCmj(
        window,
        const JumpContext(bwKgf: 20, sigmaKgf: 0.01),
      );
      expect(seg, isA<CmjRejected>());
      expect((seg as CmjRejected).reason, CmjInvalidReason.steppedOff);
    });

    test('phase bounds survive a TestRep round-trip', () {
      const p = CmjPhases(
        onset: 100,
        bwCross: 400,
        takeoff: 800,
        landing: 1200,
        end: 1800,
        sampleRate: 1000,
      );
      final restored = CmjPhases.tryFromSpans(
        p.toTestRep(0),
        sampleRate: 1000,
      )!;
      expect(restored.onset, p.onset);
      expect(restored.bwCross, p.bwCross);
      expect(restored.takeoff, p.takeoff);
      expect(restored.landing, p.landing);
      expect(restored.end, p.end);
      expect(restored.sampleRate, p.sampleRate);
    });

    test('a window-only rep is not a jump', () {
      const rep = TestRep(start: 0, end: 30000);
      expect(CmjPhases.tryFromSpans(rep, sampleRate: 1000), isNull);
    });

    test('a window ending mid-flight is incomplete', () {
      final jump = SyntheticCmj();
      final end =
          jump.takeoffIndex + (jump.flightEndIndex - jump.takeoffIndex) ~/ 2;
      final window = PlateWindow.capture(jump.reader, 0, end);
      final baseline = estimateBaseline(jump.window, 0, jump.quietEnd)!;
      final seg = segmentCmj(window, JumpContext.fromBaseline(baseline));
      expect(seg, isA<CmjRejected>());
      expect((seg as CmjRejected).reason, CmjInvalidReason.incomplete);
    });
  });
}
