import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/metric_eval.dart';
import 'package:dynamite_app/analysis/plate_series.dart';
import 'package:dynamite_app/analysis/segmentation_dj.dart';

import 'helpers/synthetic_plate.dart';

void main() {
  const bw = 80.0;

  PlateReader readerFor(SyntheticDropJump dj) {
    final corners = dj.cornerLists();
    return PlateReader.fromCornerForce(
      (corner, index) => corners[corner][index],
      sampleRate: dj.sampleRate,
    );
  }

  group('segmentDj', () {
    test('finds a complete drop jump', () {
      final dj = SyntheticDropJump(reps: 1);
      final seg = segmentDj(
        PlateWindow.capture(readerFor(dj), 0, dj.sampleCount),
        bw,
      );
      expect(seg, isA<DjRep>());
      final p = (seg as DjRep).phases;
      expect(p.touchdown, lessThan(p.takeoff));
      expect(p.takeoff, lessThan(p.landing));
      // Contact: 50 ramp + 300 hold + ~50 fall, minus threshold trims.
      expect(p.contactSamples, closeTo(400, 40));
      // Flight: the scripted 500 ms, minus threshold trims.
      expect(p.flightSamples, closeTo(500, 40));
    });

    test('standing around after touchdown is no rebound', () {
      final corners = <List<double>>[[], [], [], []];
      for (int i = 0; i < 3000; i++) {
        final t = i >= 500 ? bw : 0.0;
        for (final c in corners) {
          c.add(t / 4);
        }
      }
      final seg = segmentDj(
        PlateWindow.capture(
          PlateReader.fromCornerForce(
            (corner, index) => corners[corner][index],
            sampleRate: 1000,
          ),
          400,
          2900,
        ),
        bw,
      );
      expect(
        seg,
        isA<DjRejected>().having(
          (r) => r.reason,
          'reason',
          DjInvalidReason.noRebound,
        ),
      );
    });

    test('an empty window is no contact', () {
      final seg = segmentDj(
        PlateWindow.capture(
          PlateReader.fromCornerForce((corner, index) => 0, sampleRate: 1000),
          0,
          1000,
        ),
        bw,
      );
      expect(
        seg,
        isA<DjRejected>().having(
          (r) => r.reason,
          'reason',
          DjInvalidReason.noContact,
        ),
      );
    });

    test('phase bounds survive a TestRep round-trip', () {
      const p = DjPhases(
        touchdown: 100,
        takeoff: 500,
        landing: 1000,
        end: 1400,
        sampleRate: 1000,
      );
      final restored = DjPhases.tryFromSpans(p.toTestRep(0), sampleRate: 1000)!;
      expect(restored.touchdown, p.touchdown);
      expect(restored.takeoff, p.takeoff);
      expect(restored.landing, p.landing);
      expect(restored.end, p.end);
    });
  });

  group('drop-jump metrics', () {
    late Map<String, double?> m;

    setUpAll(() {
      final dj = SyntheticDropJump(reps: 1);
      final reader = readerFor(dj);
      const bw2 = bw;
      final seg = segmentDj(
        PlateWindow.capture(reader, 0, dj.sampleCount),
        bw2,
      );
      final p = (seg as DjRep).phases;
      m = {
        for (final v in evaluateMetrics(
          PlateWindow.capture(reader, p.touchdown, p.end),
          djMetrics,
          p,
        ))
          v.def.id: v.value,
      };
    });

    test('flight-time height matches the scripted flight', () {
      // ~500 ms airborne → ~0.307 m.
      expect(m['height_flight'], closeTo(0.307, 0.03));
    });

    test('RSI is height over contact time', () {
      expect(m['rsi'], closeTo(m['height_flight']! / 0.4, 0.2));
    });

    test('peaks track the scripted plateaus', () {
      expect(m['peak_force'], closeTo(1.8 * bw, 8));
      expect(m['peak_landing_force'], closeTo(2.0 * bw, 8));
    });
  });
}
