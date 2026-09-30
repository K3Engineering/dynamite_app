import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/metrics_single_leg.dart';
import 'package:dynamite_app/analysis/plate_series.dart';

void main() {
  const bw = 80.0;

  /// Per-corner lists from (left, right) side-load segments: [samples, l, r].
  /// Left corners carry `l` (split TL/BL evenly), right corners `r`.
  PlateReader scriptedSides(List<(int, double, double)> segments) {
    final corners = <List<double>>[[], [], [], []];
    for (final (n, l, r) in segments) {
      for (int i = 0; i < n; i++) {
        corners[0].add(l / 2);
        corners[1].add(r / 2);
        corners[2].add(l / 2);
        corners[3].add(r / 2);
      }
    }
    return PlateReader.fromCornerForce(
      (corner, index) => corners[corner][index],
      sampleRate: 1000,
    );
  }

  int totalSamples(List<(int, double, double)> segments) =>
      segments.fold(0, (s, e) => s + e.$1);

  group('findSingleLegInterval', () {
    test('locates a lift between two two-foot stances', () {
      final segments = <(int, double, double)>[
        (2000, 40, 40),
        (8000, 80, 0),
        (2000, 40, 40),
      ];
      final reader = scriptedSides(segments);
      final interval = findSingleLegInterval(
        PlateWindow.capture(reader, 0, totalSamples(segments)),
        bwKgf: bw,
      )!;
      expect(interval.start, closeTo(2000, 5));
      expect(interval.end, closeTo(10000, 5));
      expect(interval.loadedLeft, isTrue);
    });

    test('a scratch lift under the minimum hold is skipped', () {
      final segments = <(int, double, double)>[
        (2000, 40, 40),
        (1000, 80, 0), // too short to count
        (1500, 40, 40),
        (8000, 0, 80), // the real attempt, right side loaded
        (2000, 40, 40),
      ];
      final reader = scriptedSides(segments);
      final interval = findSingleLegInterval(
        PlateWindow.capture(reader, 0, totalSamples(segments)),
        bwKgf: bw,
      )!;
      expect(interval.start, greaterThan(3500));
      expect(interval.end - interval.start, closeTo(8000, 20));
      expect(interval.loadedLeft, isFalse);
    });

    test('a hop-off (emptied plate) ends the interval', () {
      final segments = <(int, double, double)>[
        (2000, 40, 40),
        (3000, 80, 0),
        (500, 0, 0), // airborne
        (2000, 40, 40),
      ];
      final reader = scriptedSides(segments);
      final interval = findSingleLegInterval(
        PlateWindow.capture(reader, 0, totalSamples(segments)),
        bwKgf: bw,
      )!;
      expect(interval.end, closeTo(5000, 20));
    });

    test('no lift in the window means no interval', () {
      final segments = <(int, double, double)>[(10000, 40, 40)];
      final reader = scriptedSides(segments);
      expect(
        findSingleLegInterval(
          PlateWindow.capture(reader, 0, totalSamples(segments)),
          bwKgf: bw,
        ),
        isNull,
      );
    });
  });

  group('single-leg metrics', () {
    test('hold duration and stance load on a clean left stand', () {
      final segments = <(int, double, double)>[(8000, 80, 0)];
      final reader = scriptedSides(segments);
      final rep = evaluateSlWindow(
        PlateWindow.capture(reader, 0, 8000),
        'Left leg',
        1,
      );
      final m = {for (final v in rep.eval.values) v.def.id: v.value};
      expect(m['hold_duration'], closeTo(8, 0.01));
      expect(m['stance_load'], closeTo(100, 0.5));
    });
  });
}
