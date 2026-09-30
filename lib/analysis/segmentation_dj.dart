import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../models/graph_data_source.dart';
import 'events.dart';
import 'metric_eval.dart';
import 'plate_series.dart';
import 'test_result.dart';

// ---------------------------------------------------------------------------
// Drop-jump segmentation and metrics
//
// The athlete steps off a box onto the plate and rebounds immediately:
// touchdown, ground contact, takeoff, flight, landing. Impulse-based height
// is NOT computable here — the COM arrives with unknown downward velocity,
// so the integral can't be seeded. Flight time alone gives the height.
// ---------------------------------------------------------------------------

/// Tunables of [segmentDj]. Fractions are of body weight; starting guesses
/// to tune against real drop jumps.
@immutable
class DjParams {
  const DjParams({
    this.loadFraction = 0.05,
    this.sustainMs = 10,
    this.minContactMs = 80,
    this.maxContactMs = 900,
    this.flightLoadFraction = 0.02,
    this.minFlightMs = 80,
    this.maxFlightMs = 1200,
    this.minLandingMs = 50,
  });

  /// Touchdown is total force above this fraction of body weight.
  final double loadFraction;

  /// Contact entry/exit must hold this long.
  final int sustainMs;

  /// Contact outside this range isn't a rebound: a tap, or standing around.
  final int minContactMs;
  final int maxContactMs;

  /// Airborne is total force below this fraction of body weight.
  final double flightLoadFraction;

  final int minFlightMs;
  final int maxFlightMs;

  /// Reject a window that ends before this much landing data.
  final int minLandingMs;
}

const DjParams kDjParams = DjParams();

/// Why a window could not be segmented into a drop jump.
enum DjInvalidReason {
  /// Nobody landed (live preview or a full silence).
  noContact,

  /// Contact but no rebound flight.
  noFlight,

  /// Stayed on the ground far too long for a drop jump (a step, not a
  /// rebound).
  noRebound,

  /// Airborne implausibly long: the athlete left the plate.
  steppedOff,

  /// The window ends before the landing settles.
  incomplete,
}

sealed class DjSegment {
  const DjSegment();
}

/// A complete drop jump.
final class DjRep extends DjSegment {
  const DjRep(this.phases);
  final DjPhases phases;
}

/// No usable drop jump, with the reason.
final class DjRejected extends DjSegment {
  const DjRejected(this.reason);
  final DjInvalidReason reason;
}

/// Phase boundaries as absolute sample indices. Contact is `[touchdown,
/// takeoff]` inclusive; flight is `(takeoff, landing)` exclusive.
@immutable
class DjPhases {
  const DjPhases({
    required this.touchdown,
    required this.takeoff,
    required this.landing,
    required this.end,
    required this.sampleRate,
  });

  static const labelContact = 'contact';
  static const labelFlight = 'flight';
  static const labelLanding = 'landing';

  final int touchdown;
  final int takeoff;
  final int landing;

  /// Exclusive end of the analysed window.
  final int end;
  final int sampleRate;

  int get contactSamples => takeoff - touchdown + 1;
  int get flightSamples => landing - takeoff - 1;

  double get flightSeconds => flightSamples / sampleRate;

  /// Phase spans `[start, end)` for overlay shading and persistence.
  List<PhaseSpan> get spans => [
    PhaseSpan(label: labelContact, start: touchdown, end: takeoff + 1),
    PhaseSpan(label: labelFlight, start: takeoff + 1, end: landing),
    PhaseSpan(label: labelLanding, start: landing, end: end),
  ];

  /// This rep as a persistable [TestRep], shifted by [delta] samples (from
  /// the live source's index space into the recording slice's).
  TestRep toTestRep(int delta) => TestRep(
    start: touchdown + delta,
    end: end + delta,
    spans: [for (final s in spans) s.shifted(delta)],
  );

  /// Rebuild the phase bounds from a persisted [TestRep]'s spans, or null
  /// when the contact span is missing (not a drop-jump rep). [sampleRate]
  /// is the recording's own (not persisted per rep).
  static DjPhases? tryFromSpans(TestRep rep, {required int sampleRate}) {
    PhaseSpan? span(String label) {
      for (final s in rep.spans) {
        if (s.label == label) return s;
      }
      return null;
    }

    final contact = span(labelContact);
    final flight = span(labelFlight);
    if (contact == null || flight == null) return null;
    return DjPhases(
      touchdown: contact.start,
      takeoff: contact.end - 1,
      landing: flight.end,
      end: rep.end,
      sampleRate: sampleRate,
    );
  }
}

/// Segment [w] into a drop jump, or explain why not. The window starts at
/// the touchdown crossing (the arming point).
DjSegment segmentDj(
  PlateWindow w,
  double bwKgf, {
  DjParams params = kDjParams,
}) {
  final sustain = math.max(1, (params.sustainMs * w.sampleRate) ~/ 1000);
  final touchdown = findSustainedAbove(
    w,
    w.start,
    w.end,
    params.loadFraction * bwKgf,
    sustain,
  );
  if (touchdown == null) return const DjRejected(DjInvalidReason.noContact);

  final minContact = (params.minContactMs * w.sampleRate) ~/ 1000;
  final flightThreshold = params.flightLoadFraction * bwKgf;
  final exit = findSustainedBelow(
    w,
    touchdown + minContact,
    w.end,
    flightThreshold,
    sustain,
  );
  if (exit == null) {
    // Contact may still be running (live preview), unless it already
    // overran any plausible rebound.
    final contactSamples = w.end - touchdown;
    if (contactSamples > (params.maxContactMs * w.sampleRate) ~/ 1000) {
      return const DjRejected(DjInvalidReason.noRebound);
    }
    return const DjRejected(DjInvalidReason.noFlight);
  }

  final flightStart = exit;
  int flightEnd = flightStart;
  while (flightEnd + 1 < w.end && w.smoothAt(flightEnd + 1) < flightThreshold) {
    flightEnd++;
  }
  final flightSamples = flightEnd - flightStart + 1;
  if (flightSamples > (params.maxFlightMs * w.sampleRate) ~/ 1000) {
    return const DjRejected(DjInvalidReason.steppedOff);
  }
  if (flightSamples < (params.minFlightMs * w.sampleRate) ~/ 1000) {
    return const DjRejected(DjInvalidReason.noFlight);
  }

  final contactSamples = flightStart - touchdown;
  if (contactSamples > (params.maxContactMs * w.sampleRate) ~/ 1000) {
    return const DjRejected(DjInvalidReason.noRebound);
  }

  final landing = flightEnd + 1;
  if (landing >= w.end ||
      w.end - landing < (params.minLandingMs * w.sampleRate) ~/ 1000) {
    return const DjRejected(DjInvalidReason.incomplete);
  }

  return DjRep(
    DjPhases(
      touchdown: touchdown,
      takeoff: flightStart - 1,
      landing: landing,
      end: w.end,
      sampleRate: w.sampleRate,
    ),
  );
}

// -- Metrics --

/// One evaluated drop jump: its evaluation plus the phase boundaries
/// (overlays and persistence read those straight off the phases).
@immutable
class DjRepResult {
  const DjRepResult({required this.eval, required this.phases});

  final RepEvaluation eval;
  final DjPhases phases;

  int get number => eval.number;

  double? metric(String id) => eval.metric(id);
}

/// Standard gravity for the flight-time height (same constant as the jump
/// battery).
const double _kGravity = 9.80665;

double _peakRange(PlateWindow w, int start, int end) {
  double max = double.negativeInfinity;
  for (int i = start; i <= end; i++) {
    max = math.max(max, w.smoothAt(i));
  }
  return max;
}

/// The drop-jump metric table, in display order.
final List<MetricDef<DjPhases>> djMetrics = List.unmodifiable([
  const MetricDef<DjPhases>(
    id: 'height_flight',
    label: 'Jump height (flight)',
    unit: 'm',
    decimals: 3,
    compute: _djHeight,
  ),
  const MetricDef<DjPhases>(
    id: 'rsi',
    label: 'RSI (height / contact)',
    unit: 'm/s',
    decimals: 2,
    compute: _rsi,
  ),
  MetricDef<DjPhases>(
    id: 'contact_time',
    label: 'Contact time',
    unit: 'ms',
    decimals: 0,
    compute: (w, p) => p.contactSamples / p.sampleRate * 1000,
  ),
  MetricDef<DjPhases>(
    id: 'peak_force',
    label: 'Peak force (contact)',
    unit: 'kgf',
    decimals: 1,
    compute: (w, p) => _peakRange(w, p.touchdown, p.takeoff),
  ),
  MetricDef<DjPhases>(
    id: 'peak_landing_force',
    label: 'Peak force (landing)',
    unit: 'kgf',
    decimals: 1,
    compute: (w, p) => _peakRange(w, p.landing, p.end - 1),
  ),
]);

double _djHeight(PlateWindow w, DjPhases p) =>
    _kGravity * p.flightSeconds * p.flightSeconds / 8;

/// Reactive strength index: jump height over contact time.
double? _rsi(PlateWindow w, DjPhases p) {
  final contactS = p.contactSamples / p.sampleRate;
  if (contactS <= 0) return null;
  return _djHeight(w, p) / contactS;
}

/// Evaluate one rep: phases plus every metric in [djMetrics].
DjRepResult buildDjRepResult(PlateWindow w, DjPhases phases, int number) =>
    DjRepResult(
      eval: RepEvaluation(
        number: number,
        start: phases.touchdown,
        end: phases.end,
        values: evaluateMetrics(w, djMetrics, phases),
      ),
      phases: phases,
    );

/// Recompute every rep's metrics for [result] against a loaded recording.
/// Empty when the plate can't be read or a stored window falls outside it.
List<DjRepResult> evaluateDjResult(TestResult result, GraphDataSource data) {
  final reader = PlateReader.tryForData(data);
  if (reader == null) return const [];
  final reps = <DjRepResult>[];
  for (int i = 0; i < result.reps.length; i++) {
    final rep = result.reps[i];
    final phases = DjPhases.tryFromSpans(rep, sampleRate: data.sampleRate);
    if (phases == null) continue;
    if (rep.start < data.oldestSample || rep.end > data.totalSamples) {
      continue;
    }
    reps.add(
      buildDjRepResult(
        PlateWindow.capture(reader, rep.start, rep.end),
        phases,
        i + 1,
      ),
    );
  }
  return reps;
}
