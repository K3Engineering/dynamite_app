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
  }) {
    int n(double seconds) => (seconds * sampleRate).round();
    final quiet = n(1.0);
    final unweight = n(0.25);
    final push = n(0.32);
    final release = n(0.03);
    final impact = n(0.10);
    final settle = n(0.40);
    final tail = n(0.30);

    // Ground-phase total force: quiet -> dip to 0.6 BW -> push to 2.8 BW ->
    // release to zero.
    final ground = <double>[
      for (int i = 0; i < quiet; i++) bwKg,
      for (int i = 0; i < unweight; i++) _lerp(bwKg, 0.6 * bwKg, i / unweight),
      for (int i = 0; i < push; i++) _lerp(0.6 * bwKg, 2.8 * bwKg, i / push),
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

double _lerp(double a, double b, double u) => a + (b - a) * u;

double _gaussian(math.Random rand) {
  final u1 = math.max(rand.nextDouble(), 1e-10);
  final u2 = rand.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}
