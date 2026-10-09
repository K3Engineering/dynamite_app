import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'gap_list.dart';

// ---------------------------------------------------------------------------
// Bucket aggregates
//
// Per-bucket min/max/sum machinery shared by live ingest, session loading, and
// the graph renderers' block reductions.
// ---------------------------------------------------------------------------

/// The bucket-grid resolution, shared by live and session ingest and relied on
/// by every [BucketSeries] consumer.
const int kBucketSize = 100;

/// Min/max/sum aggregates over fixed [bucketSize]-sample windows of an integer
/// series (raw values or first differences), addressed by absolute bucket index
/// stored at `b % mins.length`. Slots are only trustworthy for the most recent
/// `mins.length` buckets (older ones are overwritten by the ring wrap). Gap
/// samples hold the previous value (diff 0), so there is no missing-data state.
typedef BucketSeries = ({
  int bucketSize,
  Int32List mins,
  Int32List maxs,
  Int32List sums,

  /// Per-bucket sums in mV/V of excitation (post board map, pre tare and
  /// unit scale), when the accumulator was fed a board map (see
  /// [BucketAccumulator]). Lets [reduceBlockBuckets] produce an EXACT bucket
  /// mean for converted units: the net display map is affine in mV/V (see
  /// [EnvelopeSeries.meanFromMvV]), while the raw-sum mean is off by the
  /// board's nonlinearity. Null when unavailable -- diff accumulators,
  /// board-less channels, and permanently after [BucketAccumulator]s see
  /// their board map vanish or change mid-stream.
  Float64List? sumMvV,
  int samples,
});

/// Mutable accumulator behind a [BucketSeries]: the ring of buckets and the
/// ingest step, shared by live and session loading so both bucket identically.
class BucketAccumulator {
  /// [mvVOf] maps a raw sample to mV/V of excitation (the channel's current
  /// board map); when present, the accumulator also sums in mV/V (see
  /// [BucketSeries.sumMvV]). The sums mix data WITH the map: a mid-stream
  /// board-map change makes already-aggregated sums stale, so armed
  /// accumulators disarm permanently on a vanished map (and the live hub
  /// disarms on a replaced map) -- never serving stale-mapped sums.
  BucketAccumulator({
    required this.bucketSize,
    required int numBuckets,
    double? Function(int raw)? mvVOf,
  }) : mins = Int32List(numBuckets),
       maxs = Int32List(numBuckets),
       sums = Int32List(numBuckets),
       _mvVOf = mvVOf,
       _sumMvV = mvVOf == null ? null : Float64List(numBuckets);

  final int bucketSize;
  final Int32List mins;
  final Int32List maxs;
  final Int32List sums;

  final double? Function(int raw)? _mvVOf;

  /// The mV/V sums ring; null = unarmed (never had a map, or disarmed).
  /// Contents are trustworthy under the same ring-wrap window as [sums].
  Float64List? _sumMvV;

  int _samples = 0;

  /// Ingest [value] as sample [sampleIndex]. Samples must arrive
  /// sequentially from [sampleIndex] 0 (or the last [reset]).
  void add(int sampleIndex, int value) {
    assert(sampleIndex == _samples, 'samples must be ingested sequentially');
    final int slot = (sampleIndex ~/ bucketSize) % mins.length;
    final bool atBucketStart = sampleIndex % bucketSize == 0;
    if (atBucketStart) {
      mins[slot] = value;
      maxs[slot] = value;
      sums[slot] = value;
    } else {
      if (value < mins[slot]) mins[slot] = value;
      if (value > maxs[slot]) maxs[slot] = value;
      sums[slot] += value;
    }
    final sumsMv = _sumMvV;
    if (sumsMv != null) {
      final mv = _mvVOf!(value);
      if (mv == null) {
        // The board map is gone: partially aggregated sums can never
        // complete. One-way latch; reductions fall back to the raw-mean
        // approximation (the pre-mV behavior), never to stale sums.
        _sumMvV = null;
      } else if (atBucketStart) {
        sumsMv[slot] = mv;
      } else {
        sumsMv[slot] += mv;
      }
    }
    _samples = sampleIndex + 1;
  }

  /// Stop serving mV/V sums (see the class doc). Re-armed only by [reset]:
  /// a new stream aggregates from scratch under the then-current map.
  void disarmMvV() => _sumMvV = null;

  /// Restart ingest from sample 0; aggregates are overwritten by later [add]s.
  void reset() {
    _samples = 0;
    // Re-arm with the CURRENT map (see [disarmMvV]); the old ring is reused
    // -- stale slots are outside the validity window until rewritten, same
    // as the int rings.
    if (_sumMvV == null && _mvVOf != null) _sumMvV = Float64List(mins.length);
  }

  /// Samples ingested so far (since construction/last [reset]).
  int get samples => _samples;

  /// View for the renderers; the arrays are shared, not copied.
  BucketSeries get series => (
    bucketSize: bucketSize,
    mins: mins,
    maxs: maxs,
    sums: sums,
    sumMvV: _sumMvV,
    samples: _samples,
  );
}

/// The first-difference value to ingest for [sampleIndex]: 0 for the very first
/// sample, inside gaps, and for the first real sample after a gap (its jump
/// spans the gap, so a one-sample diff would fabricate a spike). The derivative
/// graph's exact path suppresses the same samples with NaN.
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

/// Per-sample ingest shared by live and session loading: applies the
/// [ingestDiff] rule, feeds the value and diff accumulators, and tracks
/// whole-ingest extremes. Raw storage stays with the caller.
class ChannelIngest {
  ChannelIngest({
    required this.valueBuckets,
    required this.diffBuckets,
    required this.gaps,
  });

  final BucketAccumulator valueBuckets;
  final BucketAccumulator diffBuckets;
  final GapList gaps;

  int _min = 0;
  int _max = 0;

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
    if (valueBuckets.samples == 1) {
      _min = _max = value;
    } else {
      if (value < _min) _min = value;
      if (value > _max) _max = value;
    }
  }

  /// Whole-ingest (min, max) of the raw values, null before the first
  /// sample. Never shrinks — "everything ingested since the last [reset]",
  /// which is both the live hub's stream-lifetime peak and a loaded
  /// session's whole-session peak.
  (int, int)? get extremes => valueBuckets.samples == 0 ? null : (_min, _max);

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
/// the exact per-sample evaluator plus the bucket aggregates that accelerate
/// zoomed-out reductions.
@immutable
class EnvelopeSeries {
  /// Value at an absolute sample index, in display units. NaN marks a
  /// missing (gap) sample and breaks the polyline.
  final double Function(int sampleIndex) sampleAt;

  /// Bucket aggregates of the same series, in raw integer space.
  final BucketSeries buckets;

  /// Raw-space -> display-units map matching [sampleAt].
  final double Function(double raw) rawToDisplay;

  /// The affine part of [rawToDisplay] (tare offset + unit scale) applied to
  /// an mV/V bucket mean: mean(net) == (mean(mvV) - tareMvV) * scale. Exact
  /// whenever [rawToDisplay] is affine in mV/V, which the net converter is,
  /// because each sample passes through the SAME board map -- piecewise
  /// kinks cancel inside the mean (see [BucketSeries.sumMvV]). Consumed only
  /// together with [BucketSeries.sumMvV]; null means "no exact mean
  /// available" and the raw-sum approximation is used instead (off by the
  /// board nonlinearity). Raw unit: null (its map is affine in raw already,
  /// so raw sums are exact).
  final double Function(double meanMvV)? meanFromMvV;

  /// A series with bucket-accelerated reduction (see [reduceBlockBuckets]
  /// for the accuracy tradeoff).
  ///
  /// INVARIANTS (unenforceable here, checked by tests):
  ///  * [buckets] must aggregate the SAME series [sampleAt] evaluates (raw
  ///    values for the force graph, first differences for the derivative --
  ///    diff extremes can't come from raw-value buckets, hence the dedicated
  ///    ingest-time diff buckets).
  ///  * [rawToDisplay] must agree with [sampleAt] outside gaps and be monotone
  ///    nondecreasing, so bucket extremes map exactly to display extremes.
  ///  * [meanFromMvV], when present, must satisfy
  ///    `meanFromMvV(mean f_i) == mean(rawToDisplay(r_i))` for any sample
  ///    set (the affine-in-mV/V property in its doc).
  const EnvelopeSeries.bucketed({
    required this.sampleAt,
    required this.buckets,
    required this.rawToDisplay,
    this.meanFromMvV,
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

/// Bucket-accelerated reduction of `[from, to)`; the counterpart of
/// [reduceBlockExact] used when a block spans many samples.
///
/// Approximate only in buckets straddling a block edge (at most one per edge):
/// min/max take the full bucket (conservative — an extreme is never dropped,
/// only shifted a block), and a partial bucket's sum assumes its mean is
/// uniform. Gap samples hold values, so boundary blocks bias toward the
/// pre-gap value; renderers clip gap x-ranges anyway.
///
/// Ring-wrap safety: slots are trustworthy only for the most recent
/// `numBuckets` buckets, so the straddling head bucket is detected via
/// [BucketSeries.samples] and reduced exactly through [EnvelopeSeries.sampleAt].
BlockReduction reduceBlockBuckets(EnvelopeSeries series, int from, int to) {
  final buckets = series.buckets;
  final rawToDisplay = series.rawToDisplay;
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
  int cursor = from;
  if (cursor < firstValidBucket * bs) {
    final int headEnd = math.min(to, firstValidBucket * bs);
    merge(reduceBlockExact(series.sampleAt, cursor, headEnd));
    cursor = headEnd;
    if (cursor >= to) return (min: min, max: max, sum: sum, count: count);
  }

  double rawMin = double.infinity;
  double rawMax = double.negativeInfinity;
  double rawSum = 0;
  int rawCount = 0;

  // Armed mV/V sums enable the exact bucket mean (see
  // [EnvelopeSeries.meanFromMvV]); portion-scaled like the raw sums.
  final Float64List? sumMvV = buckets.sumMvV;
  double mvSum = 0;

  final int bFirst = cursor ~/ bs;
  final int bLast = (to - 1) ~/ bs;
  for (int b = bFirst; b <= bLast; b++) {
    final int li = b % numBuckets;

    // Only the count is portion-aware; min/max/mean come from the whole
    // bucket -- this is the boundary approximation.
    int c = bs;
    if (b == bFirst) c -= cursor - b * bs;
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
    if (sumMvV != null) mvSum += sumMvV[li] * c / written;
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
    final meanFromMvV = series.meanFromMvV;
    merge((
      min: mn,
      max: mx,
      // Exact when the mV/V sums path is available: the net conversion is
      // affine in mV/V (see EnvelopeSeries.meanFromMvV). Fallback maps the
      // raw-sum mean -- exact for affine maps (raw unit; linear boards),
      // off by the board's nonlinearity (ppm-level) for piecewise ones.
      sum: (meanFromMvV != null && sumMvV != null)
          ? rawCount * meanFromMvV(mvSum / rawCount)
          : rawCount * rawToDisplay(rawSum / rawCount),
      count: rawCount,
    ));
  }

  if (count == 0) return _emptyReduction;
  return (min: min, max: max, sum: sum, count: count);
}

/// Fold the EXACT min/max of [buckets] over `[start, end)`: buckets fully
/// inside the window are folded via [foldBucket], the partial head/tail via
/// [scanExact], so the cost is O(window / bucketSize + bucketSize). Unlike
/// [reduceBlockBuckets] it cannot read an aliased slot. Callbacks fire in
/// ascending sample order.
void foldBucketRange(
  BucketSeries buckets,
  int start,
  int end, {
  required void Function(int bucketMin, int bucketMax, int from, int to)
  foldBucket,
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
  scanExact(start, bFirst * bs);
  for (int b = bFirst; b < bLastEx; b++) {
    final int li = b % numBuckets;
    foldBucket(buckets.mins[li], buckets.maxs[li], b * bs, (b + 1) * bs);
  }
  scanExact(bLastEx * bs, end);
}

/// Exact (min, max) of a series over `[start, end)`, or null when the window
/// yields no value. [sampleAt] must evaluate the SAME series (and raw space)
/// [buckets] aggregates. Display maps are applied by the caller to the two
/// returned bounds.
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
    foldBucket: (bMin, bMax, _, _) {
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
