import 'dart:math' as math;
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// FFT machinery for the spectrum pane: radix-2 transform, Hann windowing, and
// the corrections that make the dB numbers honest. Pure Dart (no Flutter) so
// the numerics are unit-testable in isolation.
// ---------------------------------------------------------------------------

/// FFT length guard rails (samples): below [kFftMinN] the pane asks for a
/// bigger window; [kFftMaxN] caps auto sizing so a zoomed-out window can't
/// request a multi-second transform per refresh.
const int kFftMinN = 128;
const int kFftMaxN = 65536;

/// The selectable FFT lengths (samples) offered by the pane's chips.
const List<int> kFftNOptions = [1024, 2048, 4096, 8192, 16384];

/// The largest power of two ≤ [x] (0 when x < 1).
int pow2Floor(int x) {
  int p = 1;
  while (p * 2 <= x) {
    p *= 2;
  }
  return x >= 1 ? p : 0;
}

/// Resolve the FFT length for a usable window of [spanSamples] against the
/// user's [requestedN] (null = auto): at most [requestedN], at most the
/// largest pow2 ≤ the span, at most [kFftMaxN]. Null when even [kFftMinN]
/// doesn't fit — the pane then tells the user to zoom in.
int? fftWindowN(int spanSamples, int? requestedN) {
  final cap = pow2Floor(math.min(spanSamples, kFftMaxN));
  if (cap < kFftMinN) return null;
  if (requestedN == null) return cap;
  final n = math.min(requestedN, cap);
  return n < kFftMinN ? null : n;
}

/// Expand [loDb, hiDb] outward to a [step] dB grid with [pad] of headroom.
/// Snapped bounds change in discrete steps, so a live spectrum's axis sweeps
/// in 10 dB jumps instead of jittering every frame.
(double, double) snapDbRange(
  double loDb,
  double hiDb, {
  double step = 10,
  double pad = 2,
}) {
  final lo = ((loDb - pad) / step).floor() * step;
  final hi = ((hiDb + pad) / step).ceil() * step;
  // Degenerate (exact-detent) inputs still get a drawable range.
  return hi > lo ? (lo, hi) : (lo, lo + step);
}

/// Radix-2 FFT with a cached Hann window. Instances hold O(n) tables plus two
/// O(n) scratch buffers, so callers keep one per n instead of rebuilding.
class Radix2Fft {
  factory Radix2Fft(int n) {
    if (n < 4 || n & (n - 1) != 0) {
      throw ArgumentError.value(n, 'n', 'must be a power of two >= 4');
    }
    final levels = n.bitLength - 1; // log2(n) for a power of two
    final rev = Int32List(n);
    for (int i = 0; i < n; i++) {
      int r = 0;
      for (int b = 0; b < levels; b++) {
        r = (r << 1) | ((i >> b) & 1);
      }
      rev[i] = r;
    }
    final cos = Float64List(n ~/ 2);
    final sin = Float64List(n ~/ 2);
    for (int i = 0; i < n ~/ 2; i++) {
      cos[i] = math.cos(-2 * math.pi * i / n);
      sin[i] = math.sin(-2 * math.pi * i / n);
    }
    final hann = Float64List(n);
    double hannSum = 0;
    for (int i = 0; i < n; i++) {
      hann[i] = 0.5 * (1 - math.cos(2 * math.pi * i / n));
      hannSum += hann[i];
    }
    return Radix2Fft._(
      n,
      rev,
      cos,
      sin,
      hann,
      hannSum / n,
      Float64List(n),
      Float64List(n),
    );
  }

  Radix2Fft._(
    this.n,
    this._rev,
    this._cos,
    this._sin,
    this._hann,
    this._hannCoherentGain,
    this._re,
    this._im,
  );

  final int n;
  final Int32List _rev;
  final Float64List _cos;
  final Float64List _sin;
  final Float64List _hann;

  /// Mean of the window (0.5 for Hann): tone energy lands at n * gain * A / 2
  /// in a bin, so the amplitude correction divides it back out.
  final double _hannCoherentGain;

  /// Scratch buffers, reused across [amplitudeSpectrum] calls to keep
  /// steady-state allocation off the UI isolate (n can reach 64k).
  final Float64List _re;
  final Float64List _im;

  /// Equivalent noise bandwidth of the Hann window, in bins (1.5). The
  /// per-√Hz spectrum mode divides amplitudes by `sqrt(binHz * hannEnbwBins)`
  /// — the normalization under which the noise floor stops depending on n.
  static const double hannEnbwBins = 1.5;

  /// Single-sided amplitude spectrum (length n/2 + 1) of [samples] (length
  /// [n]): mean removed, Hann windowed, coherent-gain and single-sided
  /// corrections applied — a sine of amplitude A centered on bin k reads ≈ A
  /// there. Bin k covers frequency `k * sampleRate / n`.
  Float64List amplitudeSpectrum(List<double> samples) {
    assert(samples.length == n);
    double mean = 0;
    for (final v in samples) {
      mean += v;
    }
    mean /= n;
    // Subtract-then-window: windowing first would leak the DC term into the
    // skirt of every low bin.
    for (int i = 0; i < n; i++) {
      _re[_rev[i]] = (samples[i] - mean) * _hann[i];
      _im[_rev[i]] = 0;
    }

    // In-place iterative butterflies at natural output order (input was
    // bit-reversed above).
    for (int len = 2; len <= n; len <<= 1) {
      final half = len >> 1;
      final step = n ~/ len;
      for (int i = 0; i < n; i += len) {
        for (int j = 0, tw = 0; j < half; j++, tw += step) {
          final c = _cos[tw];
          final s = _sin[tw];
          final i0 = i + j;
          final i1 = i0 + half;
          final r1 = _re[i1] * c - _im[i1] * s;
          final m1 = _re[i1] * s + _im[i1] * c;
          _re[i1] = _re[i0] - r1;
          _im[i1] = _im[i0] - m1;
          _re[i0] += r1;
          _im[i0] += m1;
        }
      }
    }

    final out = Float64List(n ~/ 2 + 1);
    final base = 1.0 / (n * _hannCoherentGain);
    for (int k = 0; k <= n ~/ 2; k++) {
      final mag =
          math.sqrt(_re[k] * _re[k] + _im[k] * _im[k]) *
          base *
          // Single-sided doubling, except the bins with no negative-frequency
          // partner.
          (k == 0 || k == n ~/ 2 ? 1.0 : 2.0);
      out[k] = mag;
    }
    return out;
  }
}
