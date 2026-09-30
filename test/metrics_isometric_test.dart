import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/metrics_isometric.dart';
import 'package:dynamite_app/analysis/plate_series.dart';

void main() {
  const bw = 80.0;

  PlateWindow windowFor(double Function(int index) kgf, int samples) =>
      PlateWindow.capture(
        PlateReader.fromCornerForce(
          (corner, index) => kgf(index) / 4,
          sampleRate: 1000,
        ),
        0,
        samples,
      );

  // 1.5× BW ± 10%: the iso_press band for an 80 kg baseline.
  final ctx = IsoContext.forBw(bw, 1.5, 0.10);

  Map<String, double?> metricsOf(double Function(int) kgf, int samples) {
    final rep = evaluateIsoWindow(windowFor(kgf, samples), ctx, '', 1);
    return {for (final v in rep.values) v.def.id: v.value};
  }

  group('isometric hold metrics', () {
    test('a dead-steady hold at band center', () {
      final m = metricsOf((_) => 120.0, 5000);
      expect(m['mean_force'], closeTo(120, 0.5));
      expect(m['peak_force'], closeTo(120, 0.5));
      expect(m['cv'], closeTo(0, 0.05));
      expect(m['time_in_band'], closeTo(100, 0.5));
      expect(m['drift'], closeTo(0, 0.02));
    });

    test('a linear fade reads as drift and band time', () {
      // 110 → 130 kgf over 10 s; the band is [112, 128]: the ramp spends
      // its inner 16/20 of the range inside it.
      final m = metricsOf((i) => 110 + 20 * i / 9999, 10000);
      expect(m['drift'], closeTo(2.0, 0.05));
      expect(m['time_in_band'], closeTo(80, 3));
      expect(m['mean_force'], closeTo(120, 0.5));
    });

    test('a hold out of band scores low without failing', () {
      // Holding at 1.25× BW instead of 1.5×: metrics still evaluate; the
      // band time says how far off the aim was.
      final m = metricsOf((_) => 100.0, 5000);
      expect(m['time_in_band'], 0);
      expect(m['mean_force'], closeTo(100, 0.5));
    });
  });
}
