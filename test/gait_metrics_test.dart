import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/gait.dart';
import 'package:dynamite_app/analysis/plate_series.dart';

import 'helpers/synthetic_plate.dart';

void main() {
  const bw = 80.0;

  /// A window around the walk's first scripted contact (margins before and
  /// after).
  PlateWindow firstPassWindow(SyntheticGaitWalk walk) {
    final (start, end) = walk.contacts.first;
    final corners = walk.cornerLists();
    final reader = PlateReader.fromCornerForce(
      (corner, index) => corners[corner][index],
      sampleRate: walk.sampleRate,
    );
    return PlateWindow.capture(reader, start - 100, end + 400);
  }

  group('locateGaitContact', () {
    test('finds one footstrike in its episode', () {
      final walk = SyntheticGaitWalk();
      const ctx = GaitContext(bwKgf: bw);
      final verdict = locateGaitContact(firstPassWindow(walk), ctx);
      expect(verdict, isA<GaitPass>());
      final pass = verdict as GaitPass;
      // The 700-sample contact minus threshold edge effects.
      expect(pass.toeOff - pass.touchdown, closeTo(700, 60));
    });

    test('rejects a strike leaking off the footprint edge', () {
      // Bench footprint norm in x is ~0.51 (9" sheet over 17.5" contacts);
      // CoP at ±0.8 in x hangs off the sheet.
      final corners = <List<double>>[[], [], [], []];
      for (int i = 0; i < 2000; i++) {
        final inContact = i >= 500 && i < 1300;
        final t = inContact ? bw : 0.0;
        const x = 0.8;
        corners[0].add(t / 4 * (1 - x));
        corners[1].add(t / 4 * (1 + x));
        corners[2].add(t / 4 * (1 - x));
        corners[3].add(t / 4 * (1 + x));
      }
      final reader = PlateReader.fromCornerForce(
        (corner, index) => corners[corner][index],
        sampleRate: 1000,
      );
      final verdict = locateGaitContact(
        PlateWindow.capture(reader, 400, 1700),
        const GaitContext(bwKgf: bw),
      );
      expect(
        verdict,
        isA<GaitRejected>().having(
          (r) => r.reason,
          'reason',
          GaitInvalidReason.offPlateEdge,
        ),
      );
    });

    test('rejects an episode that never bears weight', () {
      final walk = SyntheticGaitWalk(passPeaks: [0.3]);
      const ctx = GaitContext(bwKgf: bw);
      final verdict = locateGaitContact(firstPassWindow(walk), ctx);
      expect(
        verdict,
        isA<GaitRejected>().having(
          (r) => r.reason,
          'reason',
          GaitInvalidReason.underLoaded,
        ),
      );
    });
  });

  group('pass metrics', () {
    late GaitPassResult pass;
    late Map<String, double?> m;

    setUpAll(() {
      final walk = SyntheticGaitWalk();
      final corners = walk.cornerLists();
      final reader = PlateReader.fromCornerForce(
        (corner, index) => corners[corner][index],
        sampleRate: walk.sampleRate,
      );
      const ctx = GaitContext(bwKgf: bw);
      final verdict = locateGaitContact(firstPassWindow(walk), ctx);
      pass = buildGaitPassResult(reader, verdict as GaitPass, 1, ctx);
      m = {for (final v in pass.eval.values) v.def.id: v.value};
    });

    test('contact time tracks the scripted contact', () {
      expect(m['contact_time'], closeTo(700, 60));
    });

    test('peak force reaches the scripted M-peak', () {
      expect(m['peak_force'], closeTo(1.05 * bw, 1));
      expect(m['peak_force_bw'], closeTo(100 * m['peak_force']! / bw, 1));
    });

    test('loading rate tracks the rise slope', () {
      // Rise: 84 kgf over 105 ms ≈ 800 kgf/s.
      expect(m['loading_rate'], closeTo(800, 100));
    });

    test('impulse is the area under the M', () {
      // Trapezoid over the control points: 0.744 u·BW.
      expect(m['impulse'], closeTo(0.744 * bw * 0.7, 3));
    });

    test('push-off share is balanced on a symmetric CoP sweep', () {
      expect(m['pushoff_share'], closeTo(50, 4));
    });

    test('gait line length tracks the end-to-end sweep', () {
      // 1.2 normalized units along y ≈ 366 mm plus the medial wiggle.
      expect(m['gait_line_length'], greaterThan(300));
      expect(m['gait_line_length'], lessThan(600));
    });

    test('the trail covers the contact', () {
      expect(pass.trail.length, greaterThan(500));
      expect(pass.trail.first.$2, closeTo(-0.6, 0.15));
      expect(pass.trail.last.$2, closeTo(0.6, 0.15));
    });
  });
}
