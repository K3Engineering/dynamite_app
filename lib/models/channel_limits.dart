import 'dart:math' as math;

import 'bucket_series.dart';
import 'calibration.dart';

/// Severity of a channel's proximity to a measurement limit (ADC clip or
/// load cell full scale), evaluated by [ChannelLimits.levelForRaw].
enum LimitLevel {
  /// Comfortably inside every limit.
  ok,

  /// Inside the warning band: past the warning rung but not the limit rung
  /// (see [ChannelLimits.anchorsFor]). Below a 100% warning setting this
  /// means "approaching the ceiling"; above it, "past the cell's rating but
  /// inside the user's overload allowance".
  caution,

  /// At or past a limit rung: the configured limit was exceeded, or the
  /// ADC railed (data invalid).
  exceeded,
}

/// A channel's limit status at one instant: [level] is the proximity to the
/// binding limit (null when limit warnings are disabled in settings);
/// [clipDir] is the temporal rail direction (see [ChannelLimits.clipDirFor])
/// and is evaluated regardless of that setting — a railed converter is data
/// validity, not a warning preference.
typedef ChannelLimitState = ({LimitLevel? level, int clipDir});

/// A channel's measurement limits, modelled as two rungs per polarity: a
/// warning rung and a limit rung. The user's warning setting
/// (`AppSettings.lcWarnFraction`) is one rung of the load-cell ladder and
/// the cell's rated full scale the other: below 100% the setting warns and
/// FSR limits; above 100% the roles swap (FSR warns — "out of spec" — and
/// the setting limits, e.g. 200% ≈ a cell's typical mechanical overload
/// rating). With no cell assigned the ADC rail is the only rung.
///
/// Everything here is ABSOLUTE and raw-domain by design:
///   * Clipping is a property of the 24-bit converter: +/-2^23 counts,
///     regardless of tare, display unit, or front-end gain.
///   * Load cell full scale is a property of the cell's absolute output:
///     the rated mV/V applies to `mvVFromRaw(raw)`, NOT the tared net value
///     — taring under preload reduces the remaining headroom, and the
///     warnings must follow the physical load, not the displayed zero.
///
/// Every rung is clamped to the ADC rail ([anchorsFor]): on the pro (a
/// ~2.62 mV/V ceiling at nominal excitation) a 3 mV/V cell rails the ADC
/// before reaching its own rating, so a rung past the rail can never be
/// reached and the rail takes its place.
///
/// Raw anchors for the mV/V thresholds come from the board map's inverse
/// ([ChannelBoardCalibration.rawFromMvV]): factory-calibrated channels get
/// exact anchors, nominal channels the nominal chain. Tare never appears
/// here — it only shifts the DISPLAYED position of these absolute anchors
/// (the graph converts them through the channel's tared converter).
class ChannelLimits {
  ChannelLimits({required this.board, this.loadCellFsMvV});

  /// The channel's board calibration: the absolute raw <-> mV/V map.
  final ChannelBoardCalibration board;

  /// Rated full-scale output of the assigned load cell (mV/V of excitation,
  /// applied symmetrically to both polarities); null when no cell is
  /// assigned — the clip point is then the only limit.
  final double? loadCellFsMvV;

  static const int clipRawPos = adcCountsPerPolarity - 1;
  static const int clipRawNeg = -adcCountsPerPolarity;

  static bool isClipped(int raw) => clipDirFor(raw) != 0;

  /// True when the board can place absolute mV/V anchors in the raw domain:
  /// factory data, or resolved nominals for the nominal chain. A channel
  /// with neither converts nothing — the cell-FS anchors stay null then and
  /// only the ADC clip is evaluated.
  bool get _canAnchor => board.isFactoryCalibrated || board.nominals != null;

  /// Raw anchors of +/- load cell full scale (absolute mV/V inverted through
  /// the board map); null when no cell is assigned, or when the board can
  /// place no anchors ([_canAnchor]).
  late final double? lcFsRawPos = switch (loadCellFsMvV) {
    final fs? when _canAnchor => board.rawFromMvV(fs),
    _ => null,
  };
  late final double? lcFsRawNeg = switch (loadCellFsMvV) {
    final fs? when _canAnchor => board.rawFromMvV(-fs),
    _ => null,
  };

  /// True when the load-cell ladder exists: a cell is assigned AND the
  /// board can place mV/V anchors. Such channels get the gutter ribbon
  /// display; without the ladder the ADC rail is the only limit.
  bool get hasLoadCellLadder => lcFsRawPos != null;

  /// The channel's two limit rungs on one polarity, as raw anchors:
  /// [warn] is where the warning band starts, [limit] the hard stop (both
  /// closest-to-zero first, so `warn` is never past `limit`). The rungs
  /// are `min(fraction, 1)` and `max(fraction, 1)` of the cell's rating —
  /// see the class doc — or, with no cell ladder, `min(fraction, 1)` of
  /// the ADC half-scale and the rail itself.
  ///
  /// Every anchor is clamped to the ADC rail: a rung past the rail cannot
  /// be reached (the converter clips first), so the rail takes its place.
  /// A degenerate band (warn == limit, e.g. a 100% setting or a clamped
  /// rung) simply leaves no warning zone.
  ({double warn, double limit}) anchorsFor(bool positive, double fraction) {
    final double clip =
        positive ? clipRawPos.toDouble() : clipRawNeg.toDouble();
    final double warn;
    final double limit;
    if (hasLoadCellLadder) {
      final fs = loadCellFsMvV!;
      final sign = positive ? 1.0 : -1.0;
      warn = board.rawFromMvV(sign * math.min(fraction, 1.0) * fs);
      limit = board.rawFromMvV(sign * math.max(fraction, 1.0) * fs);
    } else {
      warn = math.min(fraction, 1.0) * clip;
      limit = clip;
    }
    return positive
        ? (warn: math.min(warn, clip), limit: math.min(limit, clip))
        : (warn: math.max(warn, clip), limit: math.max(limit, clip));
  }

  /// Temporal rail state of one raw sample: +1 at/above the positive ADC
  /// rail, -1 at/below the negative rail, 0 otherwise. Deliberately
  /// stateless — the clip indication exists only while the signal sits at
  /// the rail (no latching), and its direction is the sign of this value
  /// (which the pegged display number also carries).
  static int clipDirFor(int raw) => raw >= clipRawPos
      ? 1
      : raw <= clipRawNeg
      ? -1
      : 0;

  /// The worst proximity of [raw] to any active limit, against the
  /// rail-clamped rungs ([anchorsFor]). [fraction] is the user's warning
  /// setting (see `AppSettings.lcWarnFraction`).
  LimitLevel levelForRaw(int raw, double fraction) {
    if (raw >= clipRawPos || raw <= clipRawNeg) return LimitLevel.exceeded;
    final pos = anchorsFor(true, fraction);
    final neg = anchorsFor(false, fraction);
    if (raw >= pos.limit || raw <= neg.limit) return LimitLevel.exceeded;
    if (raw >= pos.warn || raw <= neg.warn) return LimitLevel.caution;
    return LimitLevel.ok;
  }
}

/// Sample intervals of `[start, end)` where [data] is on the given side of
/// [threshold] (>= if [positive], <= otherwise).
///
/// Uniform buckets (all hot / all cold) come from min/max. Mixed buckets
/// scan per-sample unless [treatMixedAsHot] — used when a bucket is ≤1 px
/// so interior edges are subpixel.
List<({int start, int end})> hotIntervals({
  required List<int> data,
  required int cap,
  required BucketSeries buckets,
  required int start,
  required int end,
  required int threshold,
  required bool positive,
  required bool treatMixedAsHot,
}) {
  if (start >= end) return const [];

  bool hotRaw(int raw) => positive ? raw >= threshold : raw <= threshold;

  final intervals = <({int start, int end})>[];
  int? open;
  void close(int at) {
    final s = open;
    if (s != null && at > s) intervals.add((start: s, end: at));
    open = null;
  }

  void scanExact(int from, int to) {
    for (int i = from; i < to; i++) {
      if (hotRaw(data[i % cap])) {
        open ??= i;
      } else {
        close(i);
      }
    }
  }

  foldBucketRange(
    buckets,
    start,
    end,
    foldBucket: (bMin, bMax, from, to) {
      final allHot = positive ? bMin >= threshold : bMax <= threshold;
      final allCold = positive ? bMax < threshold : bMin > threshold;
      if (allCold) {
        close(from);
      } else if (allHot || treatMixedAsHot) {
        open ??= from;
      } else {
        scanExact(from, to);
      }
    },
    scanExact: scanExact,
  );
  close(end);
  return intervals;
}
