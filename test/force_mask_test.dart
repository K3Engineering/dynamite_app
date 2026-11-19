import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/force_mask.dart';
import 'package:dynamite_app/analysis/plate_series.dart';

void main() {
  PlateWindow windowFor(List<double> force) {
    final reader = PlateReader.fromCornerForce(
      (corner, index) => force[index] / 4,
      sampleRate: 1000,
    );
    return PlateWindow.capture(reader, 0, force.length);
  }

  bool Function(double) below(double threshold) =>
      (f) => f < threshold;

  group('maskedRuns', () {
    test('collects maximal runs', () {
      final w = windowFor([0, 0, 5, 5, 0, 0, 0, 5, 5, 5]);
      final runs = maskedRuns(w, below(1.0));
      expect(runs, [(start: 0, end: 1), (start: 4, end: 6)]);
    });

    test('bridges short False gaps but not long ones', () {
      // Gaps of 1 and 3 samples between three runs.
      final w = windowFor([0, 1, 0, 1, 1, 1, 0, 1]);
      expect(maskedRuns(w, below(1.0)), [
        (start: 0, end: 0),
        (start: 2, end: 2),
        (start: 6, end: 6),
      ]);
      expect(maskedRuns(w, below(1.0), bridgeSamples: 2), [
        (start: 0, end: 2),
        (start: 6, end: 6),
      ]);
      expect(maskedRuns(w, below(1.0), bridgeSamples: 5), [(start: 0, end: 6)]);
    });

    test('opening drops short runs after bridging', () {
      final w = windowFor([0, 5, 0, 0, 0, 0, 0, 0]);
      // Bridging joins the 1-sample blip to the long run; min length drops
      // the blip alone.
      expect(maskedRuns(w, below(1.0), minSamples: 3), [(start: 2, end: 7)]);
      expect(maskedRuns(w, below(1.0), bridgeSamples: 30, minSamples: 3), [
        (start: 0, end: 7),
      ]);
    });

    test('run reaching the window edge is open', () {
      final w = windowFor([5, 5, 0, 0]);
      final runs = maskedRuns(w, below(1.0));
      expect(runs, [(start: 2, end: 3)]);
      expect(runIsOpen(w, runs.single, below(1.0)), isTrue);
      final w2 = windowFor([0, 0, 5, 5]);
      final runs2 = maskedRuns(w2, below(1.0));
      expect(runIsOpen(w2, runs2.single, below(1.0)), isFalse);
    });
  });
}
