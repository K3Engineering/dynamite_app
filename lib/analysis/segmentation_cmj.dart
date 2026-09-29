import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'events.dart';
import 'plate_series.dart';
import 'test_result.dart';

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

/// Which kind of jump a segmented rep is. In a battery every valid rep goes
/// into one of these buckets — a dip is a fact about the rep, never a
/// validity question.
enum JumpClass {
  /// Countermovement: an unweighting dip precedes the push.
  countermovement,

  /// Squat jump: pushed straight from a quiet hold.
  squat,
}

sealed class CmjSegment {
  const CmjSegment();
}

/// A complete jump.
final class CmjRep extends CmjSegment {
  const CmjRep(this.phases, this.jumpClass);
  final CmjPhases phases;
  final JumpClass jumpClass;
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

  /// Span labels persisted for each phase, in the order [spans] emits them.
  static const labelEccentric = 'eccentric';
  static const labelConcentric = 'concentric';
  static const labelFlight = 'flight';
  static const labelLanding = 'landing';

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

  /// Phase spans `[start, end)` for overlay shading and persistence. A
  /// squat jump has no eccentric phase — its absence in the persisted spans
  /// is exactly how a stored rep's [JumpClass] is recovered.
  List<PhaseSpan> get spans => [
    if (eccentricSamples > 0)
      PhaseSpan(label: labelEccentric, start: onset, end: bwCross),
    PhaseSpan(label: labelConcentric, start: bwCross, end: takeoff + 1),
    PhaseSpan(label: labelFlight, start: takeoff + 1, end: landing),
    PhaseSpan(label: labelLanding, start: landing, end: end),
  ];

  /// This rep as a persitable [TestRep], shifted by [delta] samples (from
  /// the live source's index space into the recording slice's).
  TestRep toTestRep(int delta) => TestRep(
    start: onset + delta,
    end: end + delta,
    sampleRate: sampleRate,
    spans: [for (final s in spans) s.shifted(delta)],
  );

  /// Rebuild the phase bounds from a persisted [TestRep]'s spans, or null
  /// when any expected span is missing (not a jump rep). No eccentric span
  /// means a squat jump: the whole ground phase is concentric.
  static CmjPhases? tryFromSpans(TestRep rep) {
    PhaseSpan? span(String label) {
      for (final s in rep.spans) {
        if (s.label == label) return s;
      }
      return null;
    }

    final concentric = span(labelConcentric);
    final flight = span(labelFlight);
    if (concentric == null || flight == null) return null;
    final eccentric = span(labelEccentric);
    return CmjPhases(
      onset: eccentric?.start ?? concentric.start,
      bwCross: eccentric?.end ?? concentric.start,
      takeoff: concentric.end - 1,
      landing: flight.end,
      end: rep.end,
      sampleRate: rep.sampleRate,
    );
  }
}

/// The quiet band around body weight in kgf, `[lower, upper)`. Movement
/// onset is a sustained exit from it — below for a countermovement dip,
/// above for a squat-jump push.
(double, double) onsetBandKgf(
  JumpContext ctx, {
  JumpParams params = kJumpParams,
}) {
  final d = math.max(
    params.onsetSigmaK * ctx.sigmaKgf,
    params.onsetMinDropFraction * ctx.bwKgf,
  );
  return (ctx.bwKgf - d, ctx.bwKgf + d);
}

/// The unweighting onset threshold in kgf: the lower band edge.
double onsetThresholdKgf(JumpContext ctx, {JumpParams params = kJumpParams}) =>
    onsetBandKgf(ctx, params: params).$1;

/// Segment [w] into a jump, or explain why not. The window starts at the
/// rep's band exit (the arming point): a countermovement jump dips from
/// there, a squat jump is already rising.
CmjSegment segmentCmj(
  PlateWindow w,
  JumpContext ctx, {
  JumpParams params = kJumpParams,
}) {
  final bw = ctx.bwKgf;
  final sustain = math.max(1, (params.onsetSustainMs * w.sampleRate) ~/ 1000);

  final flightThreshold = params.flightLoadFraction * bw;
  int? flightStart;
  for (int i = w.start; i < w.end; i++) {
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
  if (takeoff <= w.start) {
    return const CmjRejected(CmjInvalidReason.noFlight);
  }

  // Classification: a sustained dip inside the ground phase is a
  // countermovement; pushing straight out of the quiet at the window start
  // is a squat jump.
  final dipOnset = findSustainedBelow(
    w,
    w.start,
    takeoff,
    onsetThresholdKgf(ctx, params: params),
    sustain,
  );
  if (dipOnset == null) {
    return CmjRep(
      CmjPhases(
        onset: w.start,
        bwCross: w.start,
        takeoff: takeoff,
        landing: landing,
        end: w.end,
        sampleRate: w.sampleRate,
      ),
      JumpClass.squat,
    );
  }

  // Eccentric/concentric split at the upward body-weight crossing: the net
  // force is negative (COM decelerating upward) before it, positive after.
  // A force minimum is NOT usable here — force also falls to zero at takeoff.
  int? bwCross;
  for (int i = dipOnset + 1; i <= takeoff; i++) {
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
      onset: dipOnset,
      bwCross: bwCross,
      takeoff: takeoff,
      landing: landing,
      end: w.end,
      sampleRate: w.sampleRate,
    ),
    JumpClass.countermovement,
  );
}
