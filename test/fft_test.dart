import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/utils/fft.dart';

void main() {
  group('pow2Floor', () {
    test('rounds down to powers of two', () {
      expect(pow2Floor(0), 0);
      expect(pow2Floor(1), 1);
      expect(pow2Floor(1000), 512);
      expect(pow2Floor(1024), 1024);
      expect(pow2Floor(65537), 65536);
    });
  });

  group('fftWindowN', () {
    test('auto picks the largest pow2 fitting the span', () {
      expect(fftWindowN(5000, null), 4096);
      expect(fftWindowN(kFftMaxN * 4, null), kFftMaxN);
    });

    test('a request clamps down to what fits', () {
      expect(fftWindowN(5000, 8192), 4096);
      expect(fftWindowN(100000, 16384), 16384);
    });

    test('below the minimum, no transform', () {
      expect(fftWindowN(kFftMinN - 1, null), isNull);
      expect(fftWindowN(kFftMinN, null), kFftMinN);
    });
  });

  group('snapDbRange', () {
    test('snaps outward to the grid with padding', () {
      final (lo, hi) = snapDbRange(-123, -45);
      expect(lo, -130); // floor((-123 - 2) / 10) * 10
      expect(hi, -40); // ceil((-45 + 2) / 10) * 10
    });

    test('degenerate input still gets a drawable range', () {
      // Padding alone separates the snapped ends here; the degenerate guard
      // only fires when pad == 0.
      final (lo, hi) = snapDbRange(-220, -220);
      expect((lo, hi), (-230.0, -210.0));
      final (lo2, hi2) = snapDbRange(-220, -220, pad: 0);
      expect(hi2 - lo2, 10);
    });
  });

  group('Radix2Fft.amplitudeSpectrum', () {
    test('a bin-centered tone reads its true amplitude', () {
      const n = 1024;
      const amp = 0.37;
      const bin = 42;
      final fft = Radix2Fft(n);
      final samples = List<double>.generate(n, (i) {
        return amp * math.sin(2 * math.pi * bin * i / n);
      });
      final spec = fft.amplitudeSpectrum(samples);
      expect(spec.length, n ~/ 2 + 1);
      expect(spec[bin], closeTo(amp, amp * 0.01));
      // The skirt sits orders of magnitude under a bin-centered tone.
      for (final k in [10, bin - 4, bin + 4, n ~/ 3]) {
        expect(spec[k], lessThan(amp * 0.02));
      }
    });

    test('mean removal on a pure DC input empties every bin', () {
      final fft = Radix2Fft(256);
      final spec = fft.amplitudeSpectrum(List<double>.filled(256, 1.25));
      for (final v in spec) {
        expect(v.abs(), lessThan(1e-9));
      }
    });

    test('an odd Nyquist tone reads with no partner folding', () {
      const n = 512;
      const amp = 0.5;
      final fft = Radix2Fft(n);
      final samples = List<double>.generate(
        n,
        (i) => amp * math.pow(-1, i).toDouble() * 1.0,
      );
      final spec = fft.amplitudeSpectrum(samples);
      expect(spec[n ~/ 2], closeTo(amp, amp * 0.01));
    });

    test('rejects non-power-of-two lengths', () {
      expect(() => Radix2Fft(1000), throwsArgumentError);
      expect(() => Radix2Fft(2), throwsArgumentError);
    });
  });
}
