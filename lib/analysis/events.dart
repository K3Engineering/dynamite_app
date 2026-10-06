import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'plate_series.dart';

// ---------------------------------------------------------------------------
// Detection primitives over a captured plate window
//
// Quiet-baseline statistics (the scale reading and its noise floor) and the
// sustained-threshold scan that every onset/offset rule is built from. Jump-
// specific boundaries live in segmentation_cmj.dart.
// ---------------------------------------------------------------------------

/// Minimum baseline samples: 1 s at 1 kHz.
const int kBaselineMinSamples = 1000;

/// A baseline is stable when its force sigma is at most this fraction of the
/// mean load (2% of body weight).
const double kBaselineStabilityFraction = 0.02;

/// Mean and sigma of total plate force over a quiet window.
@immutable
class BaselineStats {
  const BaselineStats({
    required this.meanKgf,
    required this.sigmaKgf,
    required this.start,
    required this.end,
  });

  /// Body weight as the plate reads it, in kgf.
  final double meanKgf;

  /// Body-weight noise floor over the window, in kgf.
  final double sigmaKgf;

  final int start;
  final int end;

  int get samples => end - start;

  /// Long enough to trust.
  bool get hasEnoughSamples => samples >= kBaselineMinSamples;

  /// Quiet enough to trust.
  bool get isStable => sigmaKgf <= kBaselineStabilityFraction * meanKgf.abs();

  /// Both conditions, and a positive load (an empty plate is not a baseline).
  bool get isUsable => hasEnoughSamples && isStable && meanKgf > 0;
}

/// Population mean and sigma of total force over `[start, end)` clamped to
/// [w]. Null when the clamped window holds no sample. Reads the raw force:
/// quiet-stance noise is low-frequency (sway, heartbeat), so a smoothing
/// filter would barely shrink sigma anyway.
BaselineStats? estimateBaseline(PlateWindow w, int start, int end) {
  final s = math.max(start, w.start);
  final e = math.min(end, w.end);
  if (e - s < 1) return null;
  double sum = 0, sumSq = 0;
  for (int i = s; i < e; i++) {
    final f = w.forceAt(i);
    sum += f;
    sumSq += f * f;
  }
  final n = e - s;
  final mean = sum / n;
  final variance = (sumSq / n - mean * mean).clamp(0.0, double.infinity);
  return BaselineStats(
    meanKgf: mean,
    sigmaKgf: math.sqrt(variance),
    start: s,
    end: e,
  );
}

/// First absolute index in `[[from], [to])` where total force is strictly
/// below [threshold] for [sustain] consecutive samples, or null when the run
/// never holds inside the window.
int? findSustainedBelow(
  PlateWindow w,
  int from,
  int to,
  double threshold,
  int sustain,
) => _findSustained(w, from, to, (f) => f < threshold, sustain);

/// First absolute index in `[[from], [to])` where total force is strictly
/// above [threshold] for [sustain] consecutive samples, or null.
int? findSustainedAbove(
  PlateWindow w,
  int from,
  int to,
  double threshold,
  int sustain,
) => _findSustained(w, from, to, (f) => f > threshold, sustain);

/// First absolute index in `[[from], [to])` where total force leaves the
/// `[lower, upper]` band for [sustain] consecutive samples, or null when it
/// never does. A rep may start by dropping (countermovement) or by rising
/// (squat jump), so arming watches both directions at once.
int? findSustainedOutside(
  PlateWindow w,
  int from,
  int to,
  double lower,
  double upper,
  int sustain,
) => _findSustained(w, from, to, (f) => f < lower || f > upper, sustain);

int? _findSustained(
  PlateWindow w,
  int from,
  int to,
  bool Function(double force) holds,
  int sustain,
) {
  final start = math.max(from, w.start);
  final stop = math.min(to, w.end);
  for (int i = start; i + sustain <= stop; i++) {
    bool all = true;
    for (int k = 0; k < sustain; k++) {
      if (!holds(w.forceAt(i + k))) {
        all = false;
        break;
      }
    }
    if (all) return i;
  }
  return null;
}

/// Walk back from [index] to the first sample of the mask run containing it
/// (the last sample where [holds] fails, plus one), never earlier than
/// [bound]. A sustained-crossing search over a short trailing window finds
/// the run's in-window start; when the run began before the window, only this
/// walk recovers the true crossing — without it, the onset boundary shifts
/// with the (batch-scheduled) tick that happened to detect it.
int runStartBack(
  PlateWindow w,
  int index,
  bool Function(double force) holds,
  int bound,
) {
  var i = index;
  final floor = math.max(bound, w.start);
  while (i > floor && holds(w.forceAt(i - 1))) {
    i--;
  }
  return i;
}
