import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'events.dart';
import 'plate_series.dart';

// ---------------------------------------------------------------------------
// Countermovement-jump segmentation
//
// Offline over a captured window: find the unweighting onset, the flight
// phase, and the landing, then split the ground phase at the upward body-
// weight crossing (eccentric = net force negative, concentric = positive to
// takeoff). The live runner calls this on the growing window as a display
// preview; the saved result is recomputed from the frozen recording, so both
// agree.
// ---------------------------------------------------------------------------

/// Tunables of [segmentCmj]. Fractions are of body weight; everything here is
/// a starting guess to be tuned against real jumps.
@immutable
class JumpParams {
  const JumpParams({
    this.onsetSigmaK = 5,
    this.onsetMinDropFraction = 0.08,
    this.onsetSustainMs = 20,
    this.flightLoadFraction = 0.02,
    this.minFlightMs = 80,
    this.maxFlightMs = 1200,
    this.minLandingMs = 50,
  });

  /// Onset is force below `bw − k·sigma`.
  final double onsetSigmaK;

  /// Onset also requires a drop of at least this fraction of body weight.
  /// Body-weight noise (heartbeat, sway) can make `k·sigma` a very low bar;
  /// the floor keeps a foot shift from arming a rep, while a countermovement
  /// dips far below it.
  final double onsetMinDropFraction;

  /// Onset must hold this long.
  final int onsetSustainMs;

  /// Airborne is total force below this fraction of body weight.
  final double flightLoadFraction;

  /// Reject a flight shorter than this (no plausible jump).
  final int minFlightMs;

  /// Reject a flight longer than this: the athlete stepped off, rather than
  /// jumped.
  final int maxFlightMs;

  /// Reject a window that ends before this much landing data.
  final int minLandingMs;
}

const JumpParams kJumpParams = JumpParams();

/// The measurements segmentation needs that come from the baseline phase.
@immutable
class JumpContext {
  const JumpContext({required this.bwKgf, required this.sigmaKgf});

  factory JumpContext.fromBaseline(BaselineStats baseline) =>
      JumpContext(bwKgf: baseline.meanKgf, sigmaKgf: baseline.sigmaKgf);

  final double bwKgf;
  final double sigmaKgf;
}

/// Why a window could not be segmented into a jump.
enum CmjInvalidReason {
  /// No flight phase in the window: not a jump yet on a live preview, or the
  /// athlete never left the plate.
  noFlight,

  /// Airborne implausibly long: the athlete stepped off.
  steppedOff,

  /// The window ends before the landing settles.
  incomplete,
}

sealed class CmjSegment {
  const CmjSegment();
}

/// A complete jump.
final class CmjRep extends CmjSegment {
  const CmjRep(this.phases);
  final CmjPhases phases;
}

/// No usable jump, with the reason.
final class CmjRejected extends CmjSegment {
  const CmjRejected(this.reason);
  final CmjInvalidReason reason;
}

/// Phase boundaries as absolute sample indices. `takeoff` is the last ground
/// contact; flight is `(takeoff, landing)` exclusive. `bwCross` is the upper
/// body-weight crossing inside the ground phase (the eccentric/concentric
/// split).
@immutable
class CmjPhases {
  const CmjPhases({
    required this.onset,
    required this.bwCross,
    required this.takeoff,
    required this.landing,
    required this.end,
    required this.sampleRate,
  });

  final int onset;
  final int bwCross;
  final int takeoff;
  final int landing;

  /// Exclusive end of the analysed window.
  final int end;
  final int sampleRate;

  int get eccentricSamples => bwCross - onset;
  int get concentricSamples => takeoff - bwCross;
  int get flightSamples => landing - takeoff - 1;

  double get flightSeconds => flightSamples / sampleRate;

  /// Phase spans `[start, end)` for overlay shading, in draw order.
  List<({String label, int start, int end})> get spans => [
    (label: 'eccentric', start: onset, end: bwCross),
    (label: 'concentric', start: bwCross, end: takeoff + 1),
    (label: 'flight', start: takeoff + 1, end: landing),
    (label: 'landing', start: landing, end: end),
  ];

  /// These bounds shifted by [delta] samples (e.g. from the live source's
  /// index space into the recording slice's).
  CmjPhases shifted(int delta) => CmjPhases(
    onset: onset + delta,
    bwCross: bwCross + delta,
    takeoff: takeoff + delta,
    landing: landing + delta,
    end: end + delta,
    sampleRate: sampleRate,
  );
}

/// The unweighting onset threshold in kgf: `bw − max(k·sigma, floor·bw)`.
double onsetThresholdKgf(JumpContext ctx, {JumpParams params = kJumpParams}) =>
    ctx.bwKgf -
    math.max(
      params.onsetSigmaK * ctx.sigmaKgf,
      params.onsetMinDropFraction * ctx.bwKgf,
    );

/// Segment [w] into a jump, or explain why not.
CmjSegment segmentCmj(
  PlateWindow w,
  JumpContext ctx, {
  JumpParams params = kJumpParams,
}) {
  final bw = ctx.bwKgf;
  final sustain = math.max(1, (params.onsetSustainMs * w.sampleRate) ~/ 1000);
  final onsetThreshold = onsetThresholdKgf(ctx, params: params);
  final onset = findSustainedBelow(w, w.start, w.end, onsetThreshold, sustain);
  if (onset == null) return const CmjRejected(CmjInvalidReason.noFlight);

  final flightThreshold = params.flightLoadFraction * bw;
  int? flightStart;
  for (int i = onset; i < w.end; i++) {
    if (w.smoothAt(i) < flightThreshold) {
      flightStart = i;
      break;
    }
  }
  if (flightStart == null) {
    return const CmjRejected(CmjInvalidReason.noFlight);
  }

  int flightEnd = flightStart;
  while (flightEnd + 1 < w.end && w.smoothAt(flightEnd + 1) < flightThreshold) {
    flightEnd++;
  }
  // Checked before the ground-phase split so an instant drop to zero (a
  // step-off, where onset and takeoff coincide) is still caught.
  final flightSamples = flightEnd - flightStart + 1;
  if (flightSamples > (params.maxFlightMs * w.sampleRate) ~/ 1000) {
    return const CmjRejected(CmjInvalidReason.steppedOff);
  }
  if (flightSamples < (params.minFlightMs * w.sampleRate) ~/ 1000) {
    return const CmjRejected(CmjInvalidReason.noFlight);
  }

  final landing = flightEnd + 1;
  if (landing >= w.end ||
      w.end - landing < (params.minLandingMs * w.sampleRate) ~/ 1000) {
    return const CmjRejected(CmjInvalidReason.incomplete);
  }

  final takeoff = flightStart - 1;
  if (takeoff <= onset) {
    return const CmjRejected(CmjInvalidReason.noFlight);
  }
  // Eccentric/concentric split at the upward body-weight crossing: the net
  // force is negative (COM decelerating upward) before it, positive after.
  // A force minimum is NOT usable here — force also falls to zero at takeoff.
  int? bwCross;
  for (int i = onset + 1; i <= takeoff; i++) {
    if (w.smoothAt(i) >= bw) {
      bwCross = i;
      break;
    }
  }
  if (bwCross == null) {
    return const CmjRejected(CmjInvalidReason.noFlight);
  }

  return CmjRep(
    CmjPhases(
      onset: onset,
      bwCross: bwCross,
      takeoff: takeoff,
      landing: landing,
      end: w.end,
      sampleRate: w.sampleRate,
    ),
  );
}
