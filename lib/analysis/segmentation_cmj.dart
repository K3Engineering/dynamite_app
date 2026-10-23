import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'events.dart';
import 'force_mask.dart';
import 'plate_series.dart';
import 'test_result.dart';

// ---------------------------------------------------------------------------
// Countermovement-jump segmentation
//
// Offline over a captured window, on the RAW force trace: find the airborne
// episodes (mask below the flight threshold, bridged over ring excursions and
// toe-skim fragments), take the first episode long enough to be a flight,
// then split the ground phase at the impulse-zero point (COM turnaround, the
// bottom of the dip: net force negative before, positive after). The window
// starts at the rep's onset (band exit), so a countermovement jump dips from
// there and a squat jump is already rising.
//
// Two properties of this mechanism are worth knowing before tweaking it:
//  - No first-fragment latch: a short sub-threshold run (ring, a toe skim
//    mid-dip) is evidence of nothing; the scan moves on to a valid episode.
//    The old first-contiguous-run rule could lock a rep into permanent
//    rejection from a single above-threshold sample at flight entry.
//  - No filtering: thresholds act on raw force, so edges are sample-accurate.
//    Robustness is all in the time domain (bridge/min lengths in ms). Flight
//    bridging holds for any ring excursion shorter than the bridge — a ring
//    excursion lasts at most half a period, so the bridge covers rings down
//    to roughly 1/(2·bridge) (~8 Hz at 60 ms). We know today's plywood bench
//    rings at 19-34 Hz; nothing here is tuned to that.
// ---------------------------------------------------------------------------

/// Tunables of [segmentCmj]. Durations are in milliseconds, thresholds in
/// kgf or fractions of body weight, all validated against real jumps in
/// `profiling/lab/` (see the exploration notes there).
@immutable
class JumpParams {
  const JumpParams({
    this.onsetSigmaK = 5,
    this.onsetFloorKgf = 0.75,
    this.onsetSustainMs = 20,
    this.flightLoadFraction = 0.02,
    this.flightFloorKgf = 1.0,
    this.flightBridgeMs = 60,
    this.minFlightMs = 80,
    this.maxFlightMs = 1200,
    this.landingTailMs = 400,
  });

  /// Onset is force outside `bw ± max(k·sigma, [onsetFloorKgf])`.
  final double onsetSigmaK;

  /// Absolute noise floor for the onset band. Guards a σ→0 baseline (a
  /// dead-quiet stance would otherwise arm on anything); deliberately NOT a
  /// fraction of body weight — noise doesn't scale with the athlete.
  final double onsetFloorKgf;

  /// Onset must hold this long.
  final int onsetSustainMs;

  /// Airborne is total force below this fraction of body weight...
  final double flightLoadFraction;

  /// ...but never below this absolute floor (covers tare drift and light
  /// athletes, where the fraction would go under the noise).
  final double flightFloorKgf;

  /// Bridge sub-threshold gaps shorter than this inside a flight episode
  /// (see the file header).
  final int flightBridgeMs;

  /// Reject a flight shorter than this (no plausible jump).
  final int minFlightMs;

  /// Reject a flight longer than this: the athlete stepped off, rather than
  /// jumped.
  final int maxFlightMs;

  /// A rep's analysed window ends this long after touchdown: covers the
  /// whole landing impact (the peak lands ~100-150 ms in) so landing metrics
  /// see the event rather than its rising edge.
  final int landingTailMs;
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

  /// The window ends before the landing tail is captured.
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
/// contact; flight is `(takeoff, landing)` exclusive; `landing` is the first
/// sample back at force. `split` is the eccentric/concentric boundary: the
/// impulse-zero point where the COM stops descending (net impulse from
/// [onset] returns to zero), so the eccentric phase covers unweighting AND
/// braking. A squat jump has no eccentric phase (`split == onset`).
@immutable
class CmjPhases {
  const CmjPhases({
    required this.onset,
    required this.split,
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
  final int split;
  final int takeoff;
  final int landing;

  /// Exclusive end of the analysed window (`landing` + the landing tail).
  final int end;
  final int sampleRate;

  int get eccentricSamples => split - onset;
  int get concentricSamples => takeoff - split;
  int get flightSamples => landing - takeoff - 1;

  double get flightSeconds => flightSamples / sampleRate;

  /// Phase spans `[start, end)` for overlay shading and persistence. A
  /// squat jump has no eccentric phase — its absence in the persisted spans
  /// is exactly how a stored rep's [JumpClass] is recovered.
  List<PhaseSpan> get spans => [
    if (eccentricSamples > 0)
      PhaseSpan(label: labelEccentric, start: onset, end: split),
    PhaseSpan(label: labelConcentric, start: split, end: takeoff + 1),
    PhaseSpan(label: labelFlight, start: takeoff + 1, end: landing),
    PhaseSpan(label: labelLanding, start: landing, end: end),
  ];

  /// This rep as a persitable [TestRep], shifted by [delta] samples (from
  /// the live source's index space into the recording slice's).
  TestRep toTestRep(int delta) => TestRep(
    start: onset + delta,
    end: end + delta,
    spans: [for (final s in spans) s.shifted(delta)],
  );

  /// Rebuild the phase bounds from a persisted [TestRep]'s spans, or null
  /// when any expected span is missing (not a jump rep). No eccentric span
  /// means a squat jump: the whole ground phase is concentric. [sampleRate]
  /// is the recording's own (not persisted per rep).
  static CmjPhases? tryFromSpans(TestRep rep, {required int sampleRate}) {
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
      split: eccentric?.end ?? concentric.start,
      takeoff: concentric.end - 1,
      landing: flight.end,
      end: rep.end,
      sampleRate: sampleRate,
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
  final d = math.max(params.onsetSigmaK * ctx.sigmaKgf, params.onsetFloorKgf);
  return (ctx.bwKgf - d, ctx.bwKgf + d);
}

/// The unweighting onset threshold in kgf: the lower band edge.
double onsetThresholdKgf(JumpContext ctx, {JumpParams params = kJumpParams}) =>
    onsetBandKgf(ctx, params: params).$1;

/// The flight threshold in kgf: a body-weight fraction with an absolute
/// floor.
double flightThresholdKgf(double bwKgf, {JumpParams params = kJumpParams}) =>
    math.max(params.flightLoadFraction * bwKgf, params.flightFloorKgf);

/// The eccentric/concentric split: the impulse-zero point. Integrating the
/// net force from [onset] (where v=0), the COM velocity is most negative at
/// the minimum of the cumulative sum (the bottom of the dip) and climbs back
/// through zero where falling turns to rising — the true turnaround. Falls
/// back to the velocity minimum when the sum never recovers (a window that
/// isn't a jump; validity is the caller's problem).
int impulseZeroSplit(PlateWindow w, int onset, int takeoff, double bwKgf) {
  double net = 0, min = 0;
  int bottom = onset;
  final sums = <double>[];
  for (int i = onset; i <= takeoff; i++) {
    net += w.forceAt(i) - bwKgf;
    sums.add(net);
  }
  for (int k = 0; k < sums.length; k++) {
    if (sums[k] < min) {
      min = sums[k];
      bottom = k;
    }
  }
  for (int k = bottom; k < sums.length; k++) {
    if (sums[k] >= 0) return onset + k;
  }
  return onset + bottom;
}

/// Segment [w] into a jump, or explain why not. The window starts at the
/// rep's band exit (the arming point): a countermovement jump dips from
/// there, a squat jump is already rising.
CmjSegment segmentCmj(
  PlateWindow w,
  JumpContext ctx, {
  JumpParams params = kJumpParams,
}) {
  final bw = ctx.bwKgf;
  final sustain = math.max(1, params.onsetSustainMs * w.sampleRate ~/ 1000);
  final threshold = flightThresholdKgf(bw, params: params);
  final minFlight = params.minFlightMs * w.sampleRate ~/ 1000;
  final maxFlight = params.maxFlightMs * w.sampleRate ~/ 1000;
  final tail = params.landingTailMs * w.sampleRate ~/ 1000;

  bool airborne(double f) => f < threshold;
  final episodes = maskedRuns(
    w,
    airborne,
    bridgeSamples: params.flightBridgeMs * w.sampleRate ~/ 1000,
  );
  // The first plausible flight wins. Shorter episodes (ring fragments, a toe
  // skim mid-dip) are skipped, not latched: nothing here can poison the rep.
  MaskRun? flight;
  for (final e in episodes) {
    if (e.length > maxFlight) {
      return const CmjRejected(CmjInvalidReason.steppedOff);
    }
    if (e.length >= minFlight) {
      flight = e;
      break;
    }
  }
  if (flight == null) {
    return const CmjRejected(CmjInvalidReason.noFlight);
  }
  if (runIsOpen(w, flight, airborne)) {
    return const CmjRejected(CmjInvalidReason.incomplete);
  }

  final takeoff = flight.start - 1;
  final landing = flight.end + 1;
  final end = landing + tail;
  if (takeoff <= w.start) {
    return const CmjRejected(CmjInvalidReason.noFlight);
  }
  if (end > w.end) {
    return const CmjRejected(CmjInvalidReason.incomplete);
  }

  // Classification: a sustained dip inside the ground phase is a
  // countermovement; pushing straight out of the quiet at the window start
  // is a squat jump.
  final dip = findSustainedBelow(
    w,
    w.start,
    takeoff,
    onsetThresholdKgf(ctx, params: params),
    sustain,
  );
  if (dip == null) {
    return CmjRep(
      CmjPhases(
        onset: w.start,
        split: w.start,
        takeoff: takeoff,
        landing: landing,
        end: end,
        sampleRate: w.sampleRate,
      ),
      JumpClass.squat,
    );
  }

  return CmjRep(
    CmjPhases(
      onset: dip,
      split: impulseZeroSplit(w, dip, takeoff, bw),
      takeoff: takeoff,
      landing: landing,
      end: end,
      sampleRate: w.sampleRate,
    ),
    JumpClass.countermovement,
  );
}
