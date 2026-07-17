import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/bucket_series.dart';

/// Locks the documented invariants of the two block-reduction paths used by
/// drawChannelEnvelope:
///  * bucket-aligned, gap-free blocks reduce identically on both paths
///    (including the newest, partially filled bucket);
///  * misaligned blocks are conservative for min/max and exact in count;
///  * ring-wrapped (aliased) bucket slots are never read.
void main() {
  const int bs = 10;
  const int numBuckets = 8; // ring capacity: 80 samples

  /// Builds a bucketed series over [all] with an affine display map
  /// `(raw - tare) * k`, ingesting every sample through a BucketAccumulator.
  EnvelopeSeries buildSeries(List<int> all, {double tare = 0, double k = 1}) {
    final acc = BucketAccumulator(bucketSize: bs, numBuckets: numBuckets);
    for (int i = 0; i < all.length; i++) {
      acc.add(i, all[i]);
    }
    return EnvelopeSeries.bucketed(
      sampleAt: (j) => (all[j] - tare) * k,
      buckets: acc.series,
      rawToDisplay: (raw) => (raw - tare) * k,
    );
  }

  List<int> randomData(int n, int seed) {
    final rng = math.Random(seed);
    return List<int>.generate(n, (_) => rng.nextInt(2001) - 1000);
  }

  void expectSameReduction(BlockReduction a, BlockReduction b) {
    expect(a.count, b.count);
    expect(a.min, closeTo(b.min, 1e-9));
    expect(a.max, closeTo(b.max, 1e-9));
    expect(a.sum, closeTo(b.sum, 1e-6));
  }

  group('reduceBlockExact', () {
    test('excludes NaN (gap) samples', () {
      final values = <double>[1, 2, double.nan, 4];
      final r = reduceBlockExact((j) => values[j], 0, 4);
      expect(r.count, 3);
      expect(r.min, 1);
      expect(r.max, 4);
      expect(r.sum, 7);
    });

    test('reports count 0 for an all-gap block', () {
      final r = reduceBlockExact((_) => double.nan, 0, 10);
      expect(r.count, 0);
    });
  });

  group('reduceBlockBuckets vs reduceBlockExact', () {
    test('bucket-aligned full blocks agree exactly', () {
      final all = randomData(130, 1);
      final series = buildSeries(all, tare: 12.5, k: 0.25);
      // Valid range after wrap: samples [50, 130); buckets 5..12 live.
      for (int from = 60; from + 20 <= 130; from += 20) {
        expectSameReduction(
          reduceBlockBuckets(series, from, from + 20),
          reduceBlockExact(series.sampleAt, from, from + 20),
        );
      }
    });

    test('newest partially filled bucket is weighted exactly', () {
      final all = randomData(134, 2); // bucket 13 holds only 4 samples
      final series = buildSeries(all, tare: -3, k: 2);
      expectSameReduction(
        reduceBlockBuckets(series, 120, 134),
        reduceBlockExact(series.sampleAt, 120, 134),
      );
    });

    test('negative display multiplier keeps min <= max and exact avg', () {
      final all = randomData(130, 3);
      final series = buildSeries(all, tare: 5, k: -0.5);
      final b = reduceBlockBuckets(series, 60, 100);
      final e = reduceBlockExact(series.sampleAt, 60, 100);
      expectSameReduction(b, e);
      expect(b.min, lessThanOrEqualTo(b.max));
    });

    test('misaligned blocks: conservative min/max, exact count', () {
      final all = randomData(130, 4);
      final series = buildSeries(all);
      for (final (from, to) in [(63, 97), (61, 89), (66, 130)]) {
        final b = reduceBlockBuckets(series, from, to);
        final e = reduceBlockExact(series.sampleAt, from, to);
        expect(b.count, e.count);
        expect(b.min, lessThanOrEqualTo(e.min), reason: 'min conservative');
        expect(b.max, greaterThanOrEqualTo(e.max), reason: 'max conservative');
        // The boundary-approximated average stays inside the envelope.
        final avg = b.sum / b.count;
        expect(avg, greaterThanOrEqualTo(b.min));
        expect(avg, lessThanOrEqualTo(b.max));
      }
    });

    test(
      'aliased head bucket is reduced exactly, never from the stale slot',
      () {
        // Deterministic poison: old data is a constant 10; the wrapped live
        // edge writes huge values into the slot the oldest visible bucket
        // would hash to. Reading the stale slot would drag max to ~10133.
        const int n = 134;
        final all = List<int>.generate(n, (i) => i < 80 ? 10 : 10000 + i);
        final series = buildSeries(all);
        // bNow = 13, firstValidBucket = 6; oldest retained sample = 54.
        // Block [55, 70): samples 55..69 are all 10; bucket 5's slot (5 % 8)
        // now holds bucket 13's data (10130..10133).
        final b = reduceBlockBuckets(series, 55, 70);
        final e = reduceBlockExact(series.sampleAt, 55, 70);
        expectSameReduction(b, e);
        expect(b.max, 10); // would be 10133 if the stale slot were read
      },
    );
  });

  group('foldBucketRange', () {
    void bruteAndFold(List<int> all, int start, int end) {
      final acc = BucketAccumulator(bucketSize: bs, numBuckets: numBuckets);
      for (int i = 0; i < all.length; i++) {
        acc.add(i, all[i]);
      }

      int foldedMin = 1 << 40;
      int foldedMax = -(1 << 40);
      int scanned = 0;
      void fold(int v) {
        if (v < foldedMin) foldedMin = v;
        if (v > foldedMax) foldedMax = v;
      }

      foldBucketRange(
        acc.series,
        start,
        end,
        foldBucket: (bMin, bMax) {
          fold(bMin);
          fold(bMax);
        },
        scanExact: (from, to) {
          for (int i = from; i < to; i++) {
            fold(all[i]);
            scanned++;
          }
        },
      );

      final window = all.sublist(start, end);
      expect(foldedMin, window.reduce(math.min), reason: '[$start, $end) min');
      expect(foldedMax, window.reduce(math.max), reason: '[$start, $end) max');
      // The whole point: at most one partial bucket scanned per edge.
      expect(scanned, lessThanOrEqualTo(math.min(end - start, 2 * bs)));
    }

    test('matches brute-force min/max over random windows', () {
      final all = randomData(134, 5);
      // Windows constrained to the retained range [54, 134).
      final rng = math.Random(6);
      for (int i = 0; i < 200; i++) {
        final start = 54 + rng.nextInt(70);
        final end = start + 1 + rng.nextInt(134 - start - 1) + 1;
        bruteAndFold(all, start, math.min(end, 134));
      }
    });

    test('small windows fall back to a single exact scan', () {
      final all = randomData(134, 7);
      bruteAndFold(all, 100, 100 + 2 * bs - 1); // just under the threshold
      bruteAndFold(all, 130, 134);
    });
  });
}
