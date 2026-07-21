import 'dart:math' as math;
import 'dart:typed_data';

import 'gap_list.dart';

// ---------------------------------------------------------------------------
// Bucket aggregates
//
// The single home of the per-bucket min/max/sum machinery shared by the live
// ingest (DataHub), session loading (SessionData), and the graph renderers'
// bucket-accelerated block reductions (reduceBlockBuckets / foldBucketRange).
// ---------------------------------------------------------------------------

/// The one bucket-grid resolution shared by live (DataHub) and session
/// (SessionData) ingest; every consumer of [BucketSeries] relies on both
/// sides using the same grid, so it is defined exactly once here.
const int kBucketSize = 100;

/// Min/max/sum aggregates over fixed [bucketSize]-sample windows of some
/// integer series (raw values or first differences). Addressed by absolute
/// bucket index `b = sampleIndex ~/ bucketSize`, stored at `b % mins.length`;
/// [samples] is the total number of samples ingested, so slots are only
/// trustworthy for the most recent `mins.length` bucket indices (older ones
/// have been overwritten by the ring wrap -- see [reduceBlockBuckets]).
/// Gap samples hold the previous real value (diff 0), so buckets are always
/// fully populated and carry no missing-data state.
typedef BucketSeries = ({
  int bucketSize,
  Int32List mins,
  Int32List maxs,
  Int32List sums,
  int samples,
});

/// Mutable accumulator behind a [BucketSeries]: owns the ring of bucket
/// aggregates and the reset-or-fold ingest step. The single implementation
/// used by both the live hub and session loading, so the two can never
/// bucket differently.
class BucketAccumulator {
  BucketAccumulator({required this.bucketSize, required int numBuckets})
    : mins = Int32List(numBuckets),
      maxs = Int32List(numBuckets),
      sums = Int32List(numBuckets);

  final int bucketSize;
  final Int32List mins;
  final Int32List maxs;
  final Int32List sums;

  int _samples = 0;

  /// Ingest [value] as sample [sampleIndex]. Samples must arrive
  /// sequentially from [sampleIndex] 0 (or the last [reset]).
  void add(int sampleIndex, int value) {
    assert(sampleIndex == _samples, 'samples must be ingested sequentially');
    final int slot = (sampleIndex ~/ bucketSize) % mins.length;
    if (sampleIndex % bucketSize == 0) {
      mins[slot] = value;
      maxs[slot] = value;
      sums[slot] = value;
    } else {
      if (value < mins[slot]) mins[slot] = value;
      if (value > maxs[slot]) maxs[slot] = value;
      sums[slot] += value;
    }
    _samples = sampleIndex + 1;
  }

  /// Restart ingest from sample 0 (the aggregates themselves are
  /// overwritten lazily by subsequent [add]s).
  void reset() => _samples = 0;

  /// Immutable-shaped view for the renderers (the arrays are shared, not
  /// copied; [BucketSeries.samples] is a snapshot).
  BucketSeries get series => (
    bucketSize: bucketSize,
    mins: mins,
    maxs: maxs,
    sums: sums,
    samples: _samples,
  );
}

/// The first-difference value to ingest for [sampleIndex]: 0 for the very
/// first sample, inside gaps (held - held = 0 naturally), and for the first
/// real sample after a gap -- that jump happened over the gap's whole
/// duration, so recording it as a one-sample diff would fabricate a spike.
/// The derivative graph's exact path suppresses the same samples with NaN
/// (see DerivativeGraphPainter.sampleAt); this is the single home of the
/// ingest-side rule, shared by DataHub and SessionData.
///
/// [prevValue] is ignored (may be any value) when the result is 0 by rule.
int ingestDiff({
  required int sampleIndex,
  required int value,
  required int prevValue,
  required GapList gaps,
}) {
  if (sampleIndex == 0 || gaps.contains(sampleIndex - 1)) return 0;
  return value - prevValue;
}

/// Per-sample, per-channel ingest shared by the live hub (DataHub) and
/// session loading (SessionData) so both always bucket identically: applies
/// the gap/first-sample diff rule ([ingestDiff]) and feeds the value and
/// diff accumulators together. Raw storage and extremes tracking stay with
/// the caller — those genuinely differ (ring write vs pre-loaded array,
/// int32 vs double extremes).
class ChannelIngest {
  ChannelIngest({
    required this.valueBuckets,
    required this.diffBuckets,
    required this.gaps,
  });

  final BucketAccumulator valueBuckets;
  final BucketAccumulator diffBuckets;
  final GapList gaps;

  /// Ingest one sample. [prevValue] is the previous sample's raw value
  /// (ignored whenever the diff rule zeroes it — see [ingestDiff]).
  void add(int sampleIndex, int value, int prevValue) {
    valueBuckets.add(sampleIndex, value);
    diffBuckets.add(
      sampleIndex,
      ingestDiff(
        sampleIndex: sampleIndex,
        value: value,
        prevValue: prevValue,
        gaps: gaps,
      ),
    );
  }

  /// Restart both accumulators (new stream / reload).
  void reset() {
    valueBuckets.reset();
    diffBuckets.reset();
  }
}

// ---------------------------------------------------------------------------
// Envelope series (per-channel rendering recipe)
// ---------------------------------------------------------------------------

/// Everything needed to reduce one channel's series into min/avg/max blocks:
/// the exact per-sample evaluator plus, optionally, the bucket aggregates
/// that accelerate zoomed-out reductions.
///
/// [EnvelopeSeries.bucketed] is the only way to attach buckets, so a series
/// can never carry buckets without the matching raw->display conversion.
class EnvelopeSeries {
  /// Value at an absolute sample index, in display units. NaN marks a
  /// missing (gap) sample and breaks the polyline.
  final double Function(int sampleIndex) sampleAt;

  /// Bucket aggregates of the same series, in raw integer space; null for
  /// series that render exclusively on the exact path.
  final BucketSeries? buckets;

  /// Raw-space -> display-units map matching [sampleAt]; non-null iff
  /// [buckets] is.
  final double Function(double raw)? rawToDisplay;

  /// A series rendered exclusively on the exact per-sample path.
  EnvelopeSeries.exact(this.sampleAt) : buckets = null, rawToDisplay = null;

  /// A series with bucket-accelerated reduction (see [reduceBlockBuckets]
  /// for the accuracy tradeoff).
  ///
  /// INVARIANTS (unenforceable here, checked by tests):
  ///  * [buckets] must aggregate the SAME series [sampleAt] evaluates (raw
  ///    values for the force graph, first differences for the derivative --
  ///    diff extremes cannot be reconstructed from raw-value buckets, hence
  ///    the dedicated ingest-time diff buckets).
  ///  * [rawToDisplay] MUST be affine (e.g. tare offset + unit scale) so the
  ///    average survives the mapping, and must agree with [sampleAt]
  ///    (`sampleAt(j) == rawToDisplay(raw sample j)` outside gaps) so both
  ///    paths plot the same series.
  EnvelopeSeries.bucketed({
    required this.sampleAt,
    required BucketSeries this.buckets,
    required double Function(double raw) this.rawToDisplay,
  });
}

// ---------------------------------------------------------------------------
// Block reductions
// ---------------------------------------------------------------------------

/// One block's reduction: extremes and sum over the [count] valid samples,
/// in display units. `count == 0` means the whole block was missing data.
typedef BlockReduction = ({double min, double max, double sum, int count});

const BlockReduction _emptyReduction = (
  min: double.infinity,
  max: double.negativeInfinity,
  sum: 0,
  count: 0,
);

/// Exact per-sample reduction of `[from, to)`: every sample is evaluated
/// through [sampleAt]; NaN (gap) samples are excluded.
BlockReduction reduceBlockExact(
  double Function(int sampleIndex) sampleAt,
  int from,
  int to,
) {
  double min = double.infinity;
  double max = double.negativeInfinity;
  double sum = 0;
  int count = 0;
  for (int j = from; j < to; j++) {
    final v = sampleAt(j);
    if (v.isNaN) continue;
    sum += v;
    if (v < min) min = v;
    if (v > max) max = v;
    count++;
  }
  return (min: min, max: max, sum: sum, count: count);
}

/// Bucket-accelerated reduction of `[from, to)` for a bucketed
/// [EnvelopeSeries]; the counterpart of [reduceBlockExact] used when a block
/// spans many samples.
///
/// ## ACCURACY TRADEOFF (partial block/bucket boundaries)
///
/// The result is approximate in two ways, both confined to buckets that
/// straddle a block edge (at most one bucket per edge):
///
///  1. min/max: a boundary bucket contributes its FULL bucket min/max even
///     when the block covers only part of it, so the envelope can be up to
///     one bucket too wide at block edges -- conservative (an extreme is
///     never dropped, only shown one block early/late).
///  2. sum: a partially covered bucket contributes `bucketMean * covered`,
///     i.e. its mean is assumed uniform across the bucket. (For the newest,
///     partially FILLED bucket the mean is taken over the samples actually
///     written, so a block covering the whole written portion is exact.)
///
/// Gap samples: the buckets contain held values (diff 0), so blocks
/// overlapping a gap edge are biased toward the pre-gap value, whereas
/// [reduceBlockExact] excludes gap samples via NaN. Renderers clip all data
/// ink out of gap x-ranges, so the difference is confined to the clipped-in
/// area around gap edges.
///
/// ## Ring-wrap safety
///
/// Bucket slots are only trustworthy for the most recent `numBuckets` bucket
/// indices; the slot of the single bucket straddling the oldest retained
/// sample is overwritten by the live edge once the ring wraps. That head
/// portion is detected via [BucketSeries.samples] and reduced exactly
/// through [EnvelopeSeries.sampleAt] instead, so stale aggregates are never
/// read and no sample is silently dropped.
BlockReduction reduceBlockBuckets(EnvelopeSeries series, int from, int to) {
  final buckets = series.buckets!;
  final rawToDisplay = series.rawToDisplay!;
  final int bs = buckets.bucketSize;
  final int numBuckets = buckets.mins.length;
  final int samples = buckets.samples;

  double min = double.infinity;
  double max = double.negativeInfinity;
  double sum = 0;
  int count = 0;

  void merge(BlockReduction r) {
    if (r.count == 0) return;
    if (r.min < min) min = r.min;
    if (r.max > max) max = r.max;
    sum += r.sum;
    count += r.count;
  }

  // Exact-path fallback for the aliased head (see "Ring-wrap safety").
  final int bNow = (samples - 1) ~/ bs;
  final int firstValidBucket = math.max(0, bNow - numBuckets + 1);
  if (from < firstValidBucket * bs) {
    final int headEnd = math.min(to, firstValidBucket * bs);
    merge(reduceBlockExact(series.sampleAt, from, headEnd));
    from = headEnd;
    if (from >= to) return (min: min, max: max, sum: sum, count: count);
  }

  double rawMin = double.infinity;
  double rawMax = double.negativeInfinity;
  double rawSum = 0;
  int rawCount = 0;

  final int bFirst = from ~/ bs;
  final int bLast = (to - 1) ~/ bs;
  for (int b = bFirst; b <= bLast; b++) {
    final int li = b % numBuckets;

    // Only the count is portion-aware; min/max/mean come from the whole
    // bucket -- this is the boundary approximation.
    int c = bs;
    if (b == bFirst) c -= from - b * bs;
    if (b == bLast) c -= (b + 1) * bs - to;
    if (c <= 0) continue;

    final int bMin = buckets.mins[li];
    final int bMax = buckets.maxs[li];
    if (bMin < rawMin) rawMin = bMin.toDouble();
    if (bMax > rawMax) rawMax = bMax.toDouble();

    // Samples actually written into this bucket (< bs only for the newest,
    // still-filling bucket); its mean is sum/written, not sum/bs.
    final int written = math.min(bs, samples - b * bs);
    if (c > written) c = written; // defensive; to <= samples in practice
    rawSum += buckets.sums[li] * c / written;
    rawCount += c;
  }

  if (rawCount > 0) {
    double mn = rawToDisplay(rawMin);
    double mx = rawToDisplay(rawMax);
    if (mn > mx) {
      // A negative display multiplier flipped the ordering.
      final t = mn;
      mn = mx;
      mx = t;
    }
    merge((
      min: mn,
      max: mx,
      // Affine rawToDisplay: sum(f(x_i)) == n * f(sum(x_i) / n).
      sum: rawCount * rawToDisplay(rawSum / rawCount),
      count: rawCount,
    ));
  }

  if (count == 0) return _emptyReduction;
  return (min: min, max: max, sum: sum, count: count);
}

/// Fold the EXACT min/max of a bucket series over the sample window
/// `[start, end)`: buckets fully inside the window are folded from the
/// precomputed aggregates via [foldBucket]; the partial head/tail portions
/// are handed to [scanExact], so the cost is O(window / bucketSize +
/// bucketSize). Windows spanning fewer than two buckets fall back to a
/// single [scanExact] (aggregates would not help).
///
/// Unlike [reduceBlockBuckets] this is exact, and it cannot read an aliased
/// slot: a bucket fully inside `[start, end)` -- with the window clamped to
/// the retained sample range, as renderers always do -- is always among the
/// most recent `numBuckets` bucket indices.
void foldBucketRange(
  BucketSeries buckets,
  int start,
  int end, {
  required void Function(int bucketMin, int bucketMax) foldBucket,
  required void Function(int from, int to) scanExact,
}) {
  final int bs = buckets.bucketSize;
  if (end - start < 2 * bs) {
    scanExact(start, end);
    return;
  }
  // First/last bucket indices fully inside the window.
  final int bFirst = (start + bs - 1) ~/ bs;
  final int bLastEx = end ~/ bs;
  final int numBuckets = buckets.mins.length;
  for (int b = bFirst; b < bLastEx; b++) {
    final int li = b % numBuckets;
    foldBucket(buckets.mins[li], buckets.maxs[li]);
  }
  scanExact(start, bFirst * bs);
  scanExact(bLastEx * bs, end);
}

/// Exact (min, max) of a series over the sample window `[start, end)`, or
/// null when the window yields no value: buckets fully inside the window
/// contribute their precomputed aggregates (via [foldBucketRange]); the
/// partial head/tail portions are scanned per-sample through [sampleAt]
/// (NaN = skip, e.g. gap-edge samples of a first-difference series).
///
/// [sampleAt] must evaluate the SAME series [buckets] aggregates and in the
/// same (raw) space, so bucket bounds and scanned samples fold together.
/// Affine display maps (tare offset, unit scale) are applied by the caller to
/// the two returned bounds only.
(double, double)? windowedExtremes(
  BucketSeries buckets,
  int start,
  int end,
  double Function(int sampleIndex) sampleAt,
) {
  double mn = double.infinity;
  double mx = double.negativeInfinity;
  bool found = false;

  void fold(double v) {
    if (v < mn) mn = v;
    if (v > mx) mx = v;
    found = true;
  }

  foldBucketRange(
    buckets,
    start,
    end,
    foldBucket: (bMin, bMax) {
      fold(bMin.toDouble());
      fold(bMax.toDouble());
    },
    scanExact: (from, to) {
      for (int i = from; i < to; i++) {
        final v = sampleAt(i);
        if (v.isNaN) continue;
        fold(v);
      }
    },
  );
  return found ? (mn, mx) : null;
}
