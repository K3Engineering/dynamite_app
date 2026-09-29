import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dynamite_app/analysis/plate_series.dart';

/// Scripted per-corner kgf traces for exercising the analysis core without
/// hardware: quiet stance, countermovement, push, flight, landing, settle.
///
/// The flight duration is derived from the ground-phase impulse, so the two
/// jump-height methods (flight time vs impulse) agree by construction — a
/// consistent jump. Corner shares carry a deliberate left/right bias, so the
/// asymmetry metric has a known value.
class SyntheticCmj {
  SyntheticCmj._({
    required this.cornerKgf,
    required this.sampleRate,
    required this.quietEnd,
    required this.takeoffIndex,
    required this.flightEndIndex,
  });

  /// Corner order [TL, TR, BL, BR].
  final List<Float64List> cornerKgf;
  final int sampleRate;

  /// Exclusive end of the quiet-standing phase.
  final int quietEnd;

  /// Last ground-contact sample.
  final int takeoffIndex;

  /// Last airborne sample.
  final int flightEndIndex;

  factory SyntheticCmj({
    double bwKg = 80,
    int sampleRate = 1000,
    double leftShare = 0.55,
    double frontShare = 0.45,
    double noiseG = 0.002,
    int seed = 1,
    double ringAmplitudeKg = 0,
    double ringHz = 33,
    bool dip = true,
  }) {
    int n(double seconds) => (seconds * sampleRate).round();
    final quiet = n(1.0);
    final unweight = n(0.25);
    final push = n(0.32);
    final release = n(0.03);
    final impact = n(0.10);
    final settle = n(0.40);
    final tail = n(0.30);

    // Ground-phase total force: quiet -> push to 2.8 BW -> release to zero.
    // With [dip], a countermovement (down to 0.6 BW) precedes the push; a
    // squat jump pushes straight from quiet stance, holding BW where the dip
    // would sit (the hold is what the controller's between-rep arming sees).
    final ground = <double>[
      for (int i = 0; i < quiet; i++) bwKg,
      for (int i = 0; i < unweight; i++)
        dip ? _lerp(bwKg, 0.6 * bwKg, i / unweight) : bwKg,
      for (int i = 0; i < push; i++)
        _lerp(dip ? 0.6 * bwKg : bwKg, 2.8 * bwKg, i / push),
      for (int i = 0; i < release; i++)
        _lerp(2.8 * bwKg, 0.0, (i + 1) / release),
    ];

    // Takeoff velocity from the net impulse over the ground phase (rectangle
    // rule, matching the metrics' per-sample sum), then flight time = 2v/g.
    double v = 0;
    for (final f in ground) {
      v += 9.80665 * (f / bwKg - 1) / sampleRate;
    }
    final flight = math.max(40, (2 * v / 9.80665 * sampleRate).round());

    final total = <double>[
      ...ground,
      for (int i = 0; i < flight; i++) 0.0,
      for (int i = 0; i < impact; i++) _lerp(0.0, 2.4 * bwKg, i / impact),
      for (int i = 0; i < settle; i++) _lerp(2.4 * bwKg, bwKg, i / settle),
      for (int i = 0; i < tail; i++) bwKg,
    ];

    // Optional plate ring: a high-frequency artifact superposed on the true
    // force, as a real plate exhibits at takeoff/landing.
    if (ringAmplitudeKg > 0) {
      for (int i = 0; i < total.length; i++) {
        total[i] +=
            ringAmplitudeKg * math.sin(2 * math.pi * ringHz * i / sampleRate);
      }
    }

    final shares = [
      frontShare * leftShare,
      frontShare * (1 - leftShare),
      (1 - frontShare) * leftShare,
      (1 - frontShare) * (1 - leftShare),
    ];
    final rand = math.Random(seed);
    final corners = [for (int c = 0; c < 4; c++) Float64List(total.length)];
    for (int i = 0; i < total.length; i++) {
      final f = total[i];
      for (int c = 0; c < 4; c++) {
        corners[c][i] = f * shares[c] + _gaussian(rand) * noiseG;
      }
    }

    return SyntheticCmj._(
      cornerKgf: corners,
      sampleRate: sampleRate,
      quietEnd: quiet,
      takeoffIndex: ground.length - 1,
      flightEndIndex: ground.length + flight - 1,
    );
  }

  int get sampleCount => cornerKgf.first.length;

  PlateReader get reader => PlateReader.fromCornerForce(
    (corner, index) => cornerKgf[corner][index],
    sampleRate: sampleRate,
  );

  PlateWindow get window => PlateWindow.capture(reader, 0, sampleCount);
}

/// Scripted quiet-stance trace: constant total load whose corner split
/// follows a time-varying scripted CoP. No noise: path/RMS expectations are
/// then exact, and the controller's stability checks pass trivially.
///
/// [copX]/[copY] receive seconds and return support-normalized coordinates
/// (±1 = a plate edge).
class SyntheticSway {
  SyntheticSway({
    required this.copX,
    required this.copY,
    this.bwKg = 80,
    this.samples = 2000,
    this.sampleRate = 1000,
  });

  final double Function(double seconds) copX;
  final double Function(double seconds) copY;
  final double bwKg;
  final int samples;
  final int sampleRate;

  /// Corner weights of one sample, in [TL, TR, BL, BR] order. Corners share
  /// the product split, so the CoP is exactly the scripted one.
  (double, double, double, double) cornersAt(int index) {
    final t = index / sampleRate;
    final x = copX(t);
    final y = copY(t);
    final quarter = bwKg / 4;
    return (
      quarter * (1 - x) * (1 + y),
      quarter * (1 + x) * (1 + y),
      quarter * (1 - x) * (1 - y),
      quarter * (1 + x) * (1 - y),
    );
  }

  /// Per-corner lists in [TL, TR, BL, BR] order (for the controller's fake
  /// plate source).
  List<List<double>> cornerLists() {
    final corners = <List<double>>[[], [], [], []];
    for (int i = 0; i < samples; i++) {
      final c = cornersAt(i);
      corners[0].add(c.$1);
      corners[1].add(c.$2);
      corners[2].add(c.$3);
      corners[3].add(c.$4);
    }
    return corners;
  }

  PlateReader get reader => PlateReader.fromCornerForce(
    (corner, index) => switch (cornersAt(index)) {
      (final tl, final tr, final bl, final br) => [tl, tr, bl, br][corner],
    },
    sampleRate: sampleRate,
  );

  PlateWindow get window => PlateWindow.capture(reader, 0, samples);
}

/// Scripted gait walk-by: a full-weight stance (for the body-weight
/// baseline), then passes of M-shaped single-footstrikes through the plate
/// with empty gaps between. The CoP rolls from one plate end to the other
/// during each contact with a light medial wiggle.
class SyntheticGaitWalk {
  SyntheticGaitWalk({
    this.bwKg = 80,
    this.sampleRate = 1000,
    this.stanceSamples = 2000,
    this.passPeaks = const [1.05, 1.05],
  });

  final double bwKg;
  final int sampleRate;
  final int stanceSamples;

  /// Height of the first M-peak per pass, in multiples of body weight
  /// (second peak sits at 0.95 of this).
  final List<double> passPeaks;

  /// Contact length per pass, in samples.
  static const int contactSamples = 700;

  /// Empty-plate gaps around each pass (before and after), in samples.
  static const int gapSamples = 400;

  int get sampleCount =>
      stanceSamples + passPeaks.length * (gapSamples * 2 + contactSamples);

  /// Script contact bounds (before boxcar smoothing), absolute indices.
  List<(int start, int end)> get contacts => [
    for (int k = 0; k < passPeaks.length; k++)
      (
        stanceSamples + k * (gapSamples * 2 + contactSamples) + gapSamples,
        stanceSamples +
            k * (gapSamples * 2 + contactSamples) +
            gapSamples +
            contactSamples,
      ),
  ];

  (double total, double x, double y) _stateAt(int index) {
    if (index < stanceSamples) return (bwKg, 0, 0);
    final rest = index - stanceSamples;
    const stride = gapSamples * 2 + contactSamples;
    final k = rest ~/ stride;
    if (k >= passPeaks.length) return (0, 0, 0);
    final within = rest % stride;
    if (within < gapSamples || within >= gapSamples + contactSamples) {
      return (0, 0, 0);
    }
    final u = (within - gapSamples) / contactSamples;
    final peak = passPeaks[k];
    // M-profile control points: rise, valley, second peak, fall.
    final shape = _piecewise(u, [
      (0.0, 0.0),
      (0.15, peak),
      (0.40, 0.85 * peak),
      (0.70, 0.95 * peak),
      (1.0, 0.0),
    ]);
    return (bwKg * shape, 0.05 * math.sin(2 * math.pi * 3 * u), -0.6 + 1.2 * u);
  }

  /// Corner weights of one sample, in [TL, TR, BL, BR] order.
  (double, double, double, double) cornersAt(int index) {
    final (t, x, y) = _stateAt(index);
    final quarter = t / 4;
    return (
      quarter * (1 - x) * (1 + y),
      quarter * (1 + x) * (1 + y),
      quarter * (1 - x) * (1 - y),
      quarter * (1 + x) * (1 - y),
    );
  }

  /// Per-corner lists in [TL, TR, BL, BR] order.
  List<List<double>> cornerLists() {
    final corners = <List<double>>[[], [], [], []];
    for (int i = 0; i < sampleCount; i++) {
      final c = cornersAt(i);
      corners[0].add(c.$1);
      corners[1].add(c.$2);
      corners[2].add(c.$3);
      corners[3].add(c.$4);
    }
    return corners;
  }
}

/// Piecewise-linear interpolation through [points] (sorted by progress).
double _piecewise(double u, List<(double, double)> points) {
  for (int i = 1; i < points.length; i++) {
    if (u <= points[i].$1) {
      final (x0, y0) = points[i - 1];
      final (x1, y1) = points[i];
      return y0 + (y1 - y0) * (u - x0) / (x1 - x0);
    }
  }
  return points.last.$2;
}

double _lerp(double a, double b, double u) => a + (b - a) * u;

double _gaussian(math.Random rand) {
  final u1 = math.max(rand.nextDouble(), 1e-10);
  final u2 = rand.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}
