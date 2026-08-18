import 'board_calibration.dart';
import 'bucket_series.dart';

/// ADC-rail clip checks. Clipping is a property of the 24-bit converter:
/// +/-2^23 counts, regardless of tare, display unit, or front-end gain.
class ChannelLimits {
  static const int clipRawPos = adcCountsPerPolarity - 1;
  static const int clipRawNeg = -adcCountsPerPolarity;

  static bool isClipped(int raw) => raw >= clipRawPos || raw <= clipRawNeg;
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
