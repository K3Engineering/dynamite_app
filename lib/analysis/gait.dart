import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../models/graph_data_source.dart';
import '../models/graph_overlays.dart';
import 'events.dart';
import 'metric_eval.dart';
import 'plate_series.dart';
import 'result_overlays.dart';
import 'test_result.dart';

// ---------------------------------------------------------------------------
// Gait pass analysis
//
// One plate sees one footstrike per walk-by. A pass is a loading episode on
// the otherwise empty plate: touchdown when force rises over the threshold,
// toe-off when it drops back. Episodes are scanned live by the runner; the
// saved windows are re-evaluated with the same definitions when a session
// re-opens.
// ---------------------------------------------------------------------------

/// Tunables of gait segmentation. Fractions are of body weight; starting
/// guesses to tune against real walk-bys.
@immutable
class GaitParams {
  const GaitParams({
    this.loadFraction = 0.05,
    this.onsetSustainMs = 20,
    this.settleMs = 300,
    this.minContactMs = 100,
    this.maxContactMs = 2000,
    this.minPeakFraction = 0.5,
  });

  /// A foot counts as on the plate when total force clears this fraction of
  /// body weight.
  final double loadFraction;

  /// Contact entry must hold this long.
  final int onsetSustainMs;

  /// An episode ends after this much time back under the load threshold.
  final int settleMs;

  /// Reject a contact shorter than this (a tap, an accidental touch).
  final int minContactMs;

  /// Reject a contact longer than this (the person stopped on the plate —
  /// a quiet stance, not a footstrike).
  final int maxContactMs;

  /// Reject an episode that never bears at least this much body weight (a
  /// partial strike, or walking on tiptoe along the edge).
  final double minPeakFraction;
}

const GaitParams kGaitParams = GaitParams();

/// Baseline facts gait metrics need: body weight from the stance phase.
@immutable
class GaitContext {
  const GaitContext({required this.bwKgf});

  final double bwKgf;
}

/// Why an episode is not a usable footstrike.
enum GaitInvalidReason {
  /// The CoP left the footprint during contact — the foot clipped an edge.
  offPlateEdge,

  /// Contact too short (a tap) or too long (stood still on the plate).
  contactLength,

  /// Never carried enough body weight to be a real footstrike.
  underLoaded,
}

/// The result of locating and validating the contact in an episode window.
sealed class GaitEpisode {
  const GaitEpisode();
}

/// A usable pass: contact bounds inside the window (absolute indices, first
/// and last sample over the load threshold).
final class GaitPass extends GaitEpisode {
  const GaitPass(this.touchdown, this.toeOff);

  final int touchdown;
  final int toeOff;
}

/// Not a usable pass, with the reason.
final class GaitRejected extends GaitEpisode {
  const GaitRejected(this.reason);
  final GaitInvalidReason reason;
}

/// Sample bounds of one episode (a loading event plus margins).
typedef EpisodeBounds = ({int start, int end});

/// Locate the contact inside an episode window and validate it.
///
/// [w] holds the episode plus the settle tail; validation and every metric
/// use the contact `[touchdown, toeOff]` within it.
GaitEpisode locateGaitContact(
  PlateWindow w,
  GaitContext ctx, {
  GaitParams params = kGaitParams,
}) {
  final threshold = params.loadFraction * ctx.bwKgf;
  final sustain = math.max(1, params.onsetSustainMs * w.sampleRate ~/ 1000);

  final touchdown = findSustainedAbove(w, w.start, w.end, threshold, sustain);
  if (touchdown == null) {
    return const GaitRejected(GaitInvalidReason.underLoaded);
  }

  int? toeOff;
  for (int i = w.end - sustain; i >= touchdown; i--) {
    bool all = true;
    for (int k = 0; k < sustain; k++) {
      if (!(w.forceAt(i + k) > threshold)) {
        all = false;
        break;
      }
    }
    if (all) {
      toeOff = i + sustain - 1;
      break;
    }
  }
  if (toeOff == null) {
    return const GaitRejected(GaitInvalidReason.underLoaded);
  }

  final contactMs = (toeOff - touchdown + 1) * 1000 ~/ w.sampleRate;
  if (contactMs < params.minContactMs || contactMs > params.maxContactMs) {
    return const GaitRejected(GaitInvalidReason.contactLength);
  }

  double peak = 0;
  for (int i = touchdown; i <= toeOff; i++) {
    peak = math.max(peak, w.forceAt(i));
  }
  if (peak < params.minPeakFraction * ctx.bwKgf) {
    return const GaitRejected(GaitInvalidReason.underLoaded);
  }

  // The foot must sit inside the footprint for the whole contact; CoP near
  // an edge means part of the strike missed the plate.
  final g = w.geometry;
  for (int i = touchdown; i <= toeOff; i++) {
    final cop = w.copAt(i);
    if (cop == null) continue;
    if (cop.$1.abs() > g.footprintHalfWidthNorm ||
        cop.$2.abs() > g.footprintHalfLengthNorm) {
      return const GaitRejected(GaitInvalidReason.offPlateEdge);
    }
  }

  return GaitPass(touchdown, toeOff);
}

// -- Metrics --

/// One evaluated pass: its evaluation (contact bounds, metric values) and
/// the CoP trail during contact ("gait line") for the plate-pane overlay.
@immutable
class GaitPassResult {
  const GaitPassResult({required this.eval, required this.trail});

  final RepEvaluation eval;

  /// CoP positions over contact, support-normalized (±1 = a plate edge).
  final List<(double, double)> trail;

  int get number => eval.number;

  double? metric(String id) => eval.metric(id);
}

/// The gait metric table, in display order.
final List<MetricDef<GaitContext>> gaitMetrics = List.unmodifiable([
  MetricDef<GaitContext>(
    id: 'contact_time',
    label: 'Contact time',
    unit: 'ms',
    decimals: 0,
    compute: (w, c) => w.length / w.sampleRate * 1000,
  ),
  MetricDef<GaitContext>(
    id: 'peak_force',
    label: 'Peak force',
    unit: 'kgf',
    decimals: 1,
    compute: (w, c) => _peak(w),
  ),
  MetricDef<GaitContext>(
    id: 'peak_force_bw',
    label: 'Peak force',
    unit: '%BW',
    decimals: 0,
    compute: (w, c) => 100 * _peak(w) / c.bwKgf,
  ),
  const MetricDef<GaitContext>(
    id: 'loading_rate',
    label: 'Loading rate',
    unit: 'kgf/s',
    decimals: 0,
    compute: _loadingRate,
  ),
  MetricDef<GaitContext>(
    id: 'impulse',
    label: 'Impulse',
    unit: 'kgf·s',
    decimals: 2,
    compute: (w, c) {
      double acc = 0;
      for (int i = w.start; i < w.end; i++) {
        acc += w.forceAt(i);
      }
      return acc / w.sampleRate;
    },
  ),
  const MetricDef<GaitContext>(
    id: 'pushoff_share',
    label: 'Push-off load share',
    unit: '%',
    decimals: 1,
    compute: _pushoffShare,
  ),
  MetricDef<GaitContext>(
    id: 'gait_line_length',
    label: 'CoP path length',
    unit: 'mm',
    decimals: 0,
    compute: (w, c) => _pathMm(w),
  ),
]);

double _peak(PlateWindow w) {
  double max = 0;
  for (int i = w.start; i < w.end; i++) {
    max = math.max(max, w.forceAt(i));
  }
  return max;
}

/// The steepest per-sample rise over the first 50 ms of contact (heel-strike
/// loading rate).
double _loadingRate(PlateWindow w, GaitContext c) {
  final horizon = math.min(w.end, w.start + 50 * w.sampleRate ~/ 1000);
  double max = 0;
  for (int i = w.start; i + 1 < horizon; i++) {
    max = math.max(max, w.forceAt(i + 1) - w.forceAt(i));
  }
  return max * w.sampleRate;
}

/// CoP path length in millimetres over contact.
double? _pathMm(PlateWindow w) {
  double sum = 0;
  (double, double)? prev;
  int n = 0;
  for (int i = w.start; i < w.end; i++) {
    final cop = w.copAt(i);
    if (cop == null) continue;
    n++;
    if (prev != null) {
      final dx = (cop.$1 - prev.$1) * w.geometry.supportHalfWidthMm;
      final dy = (cop.$2 - prev.$2) * w.geometry.supportHalfLengthMm;
      sum += math.sqrt(dx * dx + dy * dy);
    }
    prev = cop;
  }
  return n < 2 ? null : sum;
}

/// Share of contact impulse borne by the push-off-end corner pair. The end
/// the CoP travels toward during contact is the push-off end, so this is
/// direction-agnostic: walking either way reports the same anatomy.
double? _pushoffShare(PlateWindow w, GaitContext c) {
  // Direction of travel: first-vs-last 5% mean CoP y. Undefined when the
  // CoP barely moves along the plate (a stomp, not a roll-through).
  double meanY(int from, int to) {
    double sum = 0;
    int n = 0;
    for (int i = from; i < to; i++) {
      final cop = w.copAt(i);
      if (cop == null) continue;
      sum += cop.$2;
      n++;
    }
    return n == 0 ? double.nan : sum / n;
  }

  final edge = math.max(1, (w.end - w.start) ~/ 20);
  final y0 = meanY(w.start, w.start + edge);
  final y1 = meanY(w.end - edge, w.end);
  if (y0.isNaN || y1.isNaN || (y1 - y0).abs() < 0.05) return null;

  final forward = y1 > y0;
  double pushoff = 0, total = 0;
  for (int i = w.start; i < w.end; i++) {
    pushoff += forward ? w.frontAt(i) : w.backAt(i);
    total += w.forceAt(i);
  }
  if (!(total > 0)) return null;
  return 100 * pushoff / total;
}

/// Build the result for a located [contact], narrowing the analysis window
/// to the contact itself.
GaitPassResult buildGaitPassResult(
  PlateReader reader,
  GaitPass contact,
  int number,
  GaitContext ctx,
) {
  final w = PlateWindow.capture(reader, contact.touchdown, contact.toeOff + 1);
  return GaitPassResult(
    eval: RepEvaluation(
      number: number,
      start: w.start,
      end: w.end,
      values: evaluateMetrics(w, gaitMetrics, ctx),
    ),
    trail: [for (int i = w.start; i < w.end; i++) ?w.copAt(i)],
  );
}

/// Evaluate one episode into a pass result, or null when it has no valid
/// footstrike.
GaitPassResult? evaluateGaitPass(
  PlateReader reader,
  EpisodeBounds episode,
  int number,
  GaitContext ctx, {
  GaitParams params = kGaitParams,
}) {
  final window = PlateWindow.capture(reader, episode.start, episode.end);
  final contact = locateGaitContact(window, ctx, params: params);
  if (contact is! GaitPass) return null;
  return buildGaitPassResult(reader, contact, number, ctx);
}

/// Recompute every pass's metrics for [result] against a loaded recording.
/// Empty when the plate can't be read or a stored window falls outside it.
List<GaitPassResult> evaluateGaitResult(
  TestResult result,
  GraphDataSource data,
) {
  final reader = PlateReader.tryForData(data);
  if (reader == null) return const [];
  final ctx = GaitContext(bwKgf: result.bodyWeightKgf);
  final passes = <GaitPassResult>[];
  for (int i = 0; i < result.reps.length; i++) {
    final rep = result.reps[i];
    if (rep.start < data.oldestSample || rep.end > data.totalSamples) {
      continue;
    }
    final pass = evaluateGaitPass(
      reader,
      (start: rep.start, end: rep.end),
      i + 1,
      ctx,
    );
    if (pass != null) passes.add(pass);
  }
  return passes;
}

/// A gait-line polyline per pass on the 2D plate pane, with matching window
/// shading on the force trace.
GraphOverlays overlaysForGaitReps(List<GaitPassResult> reps) => GraphOverlays(
  spans: windowShadeOverlays([for (final r in reps) r.eval]).spans,
  plateTrails: [
    for (final r in reps)
      PlateTrailOverlay(points: r.trail, color: gaitTrailColor(r.number)),
  ],
);
