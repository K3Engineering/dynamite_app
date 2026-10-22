import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/bucket_series.dart';
import 'package:dynamite_app/models/gap_list.dart';

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

  group('mV/V bucket sums (exact converted-unit mean)', () {
    // Piecewise board map with a kink at raw == 1000 (slope 0.5 below, 2
    // above). A block straddling the kink makes the raw-mean approximation
    // (map of the raw mean) diverge from the true mean of mapped values --
    // exactly the error the mV/V sums path removes.
    double kinkBoard(double raw) =>
        raw <= 1000 ? raw * 0.5 : 500 + (raw - 1000) * 2.0;

    /// A bucketed series over [all] with net map `(kinkBoard - tareMv) * k`;
    /// [armed] toggles the mV/V sums + exact mean wiring on/off.
    EnvelopeSeries buildKinked(
      List<int> all, {
      bool armed = true,
      double tare = 900,
      double k = 3,
    }) {
      final tareMv = kinkBoard(tare);
      final acc = BucketAccumulator(
        bucketSize: bs,
        numBuckets: numBuckets,
        mvVOf: armed ? (raw) => kinkBoard(raw.toDouble()) : null,
      );
      for (int i = 0; i < all.length; i++) {
        acc.add(i, all[i]);
      }
      return EnvelopeSeries.bucketed(
        sampleAt: (j) => (kinkBoard(all[j].toDouble()) - tareMv) * k,
        buckets: acc.series,
        rawToDisplay: (raw) => (kinkBoard(raw) - tareMv) * k,
        meanFromMvV: armed ? (meanMv) => (meanMv - tareMv) * k : null,
      );
    }

    test(
      'kink-straddling block: mV path matches the exact mean; raw path errs',
      () {
        // One bucket, values 950..1040 straddling the 1000 kink.
        final all = List<int>.generate(bs, (i) => 950 + i * 10);
        final armed = buildKinked(all);
        final disarmed = buildKinked(all, armed: false);

        final exact = reduceBlockExact(armed.sampleAt, 0, bs);
        final bArmed = reduceBlockBuckets(armed, 0, bs);
        final bDisarmed = reduceBlockBuckets(disarmed, 0, bs);

        // min/max are map-exact on both paths (monotone map).
        expect(bArmed.min, exact.min);
        expect(bArmed.max, exact.max);
        expect(bArmed.count, exact.count);
        // The mean is exact for the mV/V sums...
        expect(bArmed.sum, closeTo(exact.sum, 1e-6));
        // ...and measurably off for the raw-mean approximation (convex kink:
        // mean of mapped > mapped of mean), proving the wire-up is exercised.
        expect((bDisarmed.sum - exact.sum).abs(), greaterThan(1.0));
      },
    );

    test('disarmed accumulator serves no mV/V sums and hits the fallback', () {
      // Board map vanishes on the third sample (raw == 2); the re-ingest
      // below feeds other values, so the map stays valid after reset.
      final acc = BucketAccumulator(
        bucketSize: bs,
        numBuckets: numBuckets,
        mvVOf: (raw) => raw == 2 ? null : raw.toDouble(),
      );
      for (int i = 0; i < 2 * bs; i++) {
        acc.add(i, i);
      }
      expect(acc.series.sumMvV, isNull, reason: 'one-way disarm latch');

      final series = EnvelopeSeries.bucketed(
        sampleAt: (j) => j.toDouble(),
        buckets: acc.series,
        rawToDisplay: (raw) => raw,
        meanFromMvV: (meanMv) => meanMv,
      );
      // Identical map/id here, so the check is that the fallback formula was
      // used (same result); the kinked test above proves they CAN differ.
      final b = reduceBlockBuckets(series, 0, 2 * bs);
      expect(
        b.sum,
        closeTo(reduceBlockExact(series.sampleAt, 0, 2 * bs).sum, 1e-9),
      );

      // reset re-arms with a fresh map (a new stream).
      acc.reset();
      expect(acc.series.sumMvV, isNotNull);
      for (int i = 0; i < bs; i++) {
        acc.add(i, 10 + i);
      }
      expect(acc.series.sumMvV![0], (10 + 19) * bs / 2.0);
    });

    test('armed accumulator sums mV/V per bucket', () {
      final acc = BucketAccumulator(
        bucketSize: bs,
        numBuckets: numBuckets,
        mvVOf: (raw) => raw * 0.5,
      );
      for (int i = 0; i < 2 * bs; i++) {
        acc.add(i, i);
      }
      final sums = acc.series.sumMvV!;
      final expected = [
        for (int j = 0; j < bs; j++) j * 0.5,
      ].fold<double>(0, (a, b) => a + b);
      expect(sums[0], closeTo(expected, 1e-9));
      expect(
        sums[1],
        closeTo(
          [
            for (int j = bs; j < 2 * bs; j++) j * 0.5,
          ].fold<double>(0, (a, b) => a + b),
          1e-9,
        ),
      );
    });
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
        foldBucket: (bMin, bMax, _, _) {
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

  group('production-scale buckets (kBucketSize = 100)', () {
    // The groups above pin the invariants at a toy bucket size of 10; this
    // group runs the SAME differential checks at the production grid
    // (kBucketSize = 100, a small 8-bucket ring) over the full signed 24-bit
    // ADC range, alternating rails, silent sections and held-value gaps.
    const int bs = kBucketSize;
    const int numBuckets = 8;

    EnvelopeSeries buildSeries100(
      List<int> all, {
      double tare = 0,
      double k = 1,
    }) {
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

    List<int> fullRangeRandom(int n, int seed) {
      final rng = math.Random(seed);
      // Exhaust the full signed 24-bit ADC range.
      return List<int>.generate(n, (_) => rng.nextInt(1 << 24) - (1 << 23));
    }

    /// Alternating rails with long silent (zero) sections mixed in.
    List<int> railsAndSilence(int n) {
      const int railHi = 0x7FFFFF;
      const int railLo = -0x800000;
      return List<int>.generate(n, (i) {
        // Switch regime every 40 samples: rails, then silence, then rails
        // with flipped polarity, then silence again.
        final flip = (i ~/ 80).isEven;
        if ((i ~/ 40).isEven) {
          return (i.isEven == flip) ? railHi : railLo;
        }
        return 0;
      });
    }

    /// Random values with explicit dropouts: inside a gap the value-side
    /// ingest holds the previous sample (see DataHub.addDroppedFrames), so
    /// the test series does the same.
    List<int> heldGapsData(int n, int seed) {
      final rng = math.Random(seed);
      final all = List<int>.filled(n, 0);
      int i = 0;
      while (i < n) {
        if (i > 0 && rng.nextInt(4) == 0) {
          final hold = 15 + rng.nextInt(40);
          for (int j = 0; j < hold && i < n; i++, j++) {
            all[i] = all[i - 1];
          }
        } else {
          all[i] = rng.nextInt(1 << 24) - (1 << 23);
          i++;
        }
      }
      return all;
    }

    // Bounded-but-dense sweep of ingest lengths; each length fans out into
    // every (from, to) window containing at least one full bucket.
    const lengths = [100, 128, 160, 200, 260];

    void checkAllWindows(
      List<int> all, {
      double tare = 0,
      double k = 1,
      required String label,
    }) {
      for (final n in lengths) {
        assert(n <= all.length);
        final data = all.sublist(0, n);
        final series = buildSeries100(data, tare: tare, k: k);
        for (int from = 0; from + bs <= n; from++) {
          for (int to = from + bs; to <= n; to++) {
            final b = reduceBlockBuckets(series, from, to);
            final e = reduceBlockExact(series.sampleAt, from, to);
            final reason = '$label [$from, $to) (n=$n)';
            // The count never approximates: portions sum to the window's
            // population, exact or not.
            expect(b.count, e.count, reason: '$reason count');
            if (from % bs == 0 && to % bs == 0) {
              // Bucket-aligned windows must reduce EXACTLY (min/max come
              // from whole buckets covering exactly the window).
              expect(b.min, closeTo(e.min, 1e-9), reason: '$reason min');
              expect(b.max, closeTo(e.max, 1e-9), reason: '$reason max');
            } else {
              // Misaligned edges may only widen the envelope -- an extreme
              // is never dropped.
              expect(
                b.min,
                lessThanOrEqualTo(e.min + 1e-9),
                reason: '$reason min conservative',
              );
              expect(
                b.max,
                greaterThanOrEqualTo(e.max - 1e-9),
                reason: '$reason max conservative',
              );
            }
          }
        }
      }
    }

    test('bounded-exhaustive windows over extreme data regimes', () {
      checkAllWindows(fullRangeRandom(260, 21), label: 'fullRange');
      checkAllWindows(railsAndSilence(260), label: 'rails');
      checkAllWindows(
        heldGapsData(260, 23),
        tare: 37.5,
        k: 0.75,
        label: 'heldGaps affine',
      );
    });

    test('ring-wrapped (aliased) head never leaks a stale slot', () {
      // 8.5 buckets through an 8-bucket ring: bucket 0's slot was overwritten
      // by bucket 8 (huge values). The trustworthy window begins at sample
      // 100, and anything before it must go through the exact path.
      final all = List<int>.generate(850, (i) => i < 100 ? 10 : 8000000 + i);
      final series = buildSeries100(all);

      for (int from = 0; from < 100; from += 17) {
        for (final to in [100, 137, 250, 850]) {
          if (to <= from) continue;
          final b = reduceBlockBuckets(series, from, to);
          final e = reduceBlockExact(series.sampleAt, from, to);
          expect(b.count, e.count, reason: '[$from, $to) count');
          expect(
            b.min,
            lessThanOrEqualTo(e.min),
            reason: '[$from, $to) min conservative',
          );
          expect(
            b.max,
            greaterThanOrEqualTo(e.max),
            reason: '[$from, $to) max conservative',
          );
          if (from % bs == 0 && to % bs == 0) {
            expectSameReduction(b, e);
          }
        }
      }

      // The poison pin: a misread bucket-0 slot would drag the max to
      // ~8000849; the exact head keeps the window at its true extreme 10.
      final b = reduceBlockBuckets(series, 0, 100);
      expect(b.max, 10);
      expect(b.min, 10);

      // foldBucketRange over a window wholly inside the aliased region is
      // narrower than 2 buckets, so it must take the exact scan path (and
      // can therefore never touch the stale slot).
      int scanned = 0;
      int folds = 0;
      int foldedMin = 1 << 40, foldedMax = -(1 << 40);
      foldBucketRange(
        series.buckets,
        0,
        100,
        foldBucket: (bMin, bMax, _, _) {
          folds++;
          foldedMin = math.min(foldedMin, bMin);
          foldedMax = math.max(foldedMax, bMax);
        },
        scanExact: (from, to) {
          for (int i = from; i < to; i++) {
            scanned++;
            foldedMin = math.min(foldedMin, all[i]);
            foldedMax = math.max(foldedMax, all[i]);
          }
        },
      );
      expect(folds, 0, reason: 'never folds a bucket in the aliased head');
      expect(scanned, 100);
      expect(foldedMin, 10);
      expect(foldedMax, 10);
    });

    test(
      'a complete aligned block reduces identically mid-fill and after fill',
      () {
        // The bug the block-alignment fix (commit d035564) killed: a block
        // reduced while the NEWEST bucket was still filling could cache a
        // min/max that differed from the same reduction after more ingest.
        // Drive a live accumulator, reduce each bucket-aligned block when
        // the newest bucket is half-full, then again when full, then again
        // after several more buckets -- every result must equal the exact
        // reduction for that block.
        const int n = 550; // stays inside the 800-sample ring
        final all = fullRangeRandom(n, 99);
        final acc = BucketAccumulator(bucketSize: bs, numBuckets: numBuckets);
        EnvelopeSeries series() => EnvelopeSeries.bucketed(
          sampleAt: (j) => all[j].toDouble(),
          buckets: acc.series,
          rawToDisplay: (raw) => raw,
        );

        void ingestTo(int count) {
          for (int i = acc.samples; i < count; i++) {
            acc.add(i, all[i]);
          }
        }

        const blocks = [(0, 100), (100, 200), (0, 200), (300, 500), (0, 500)];
        final snapshots = <List<BlockReduction>>[];
        for (final fillPoint in [250, 300, 550]) {
          ingestTo(fillPoint); // 250: newest bucket half-full, 300: just full
          final round = [
            for (final (f, t) in blocks)
              if (t <= fillPoint) reduceBlockBuckets(series(), f, t),
          ];
          for (int i = 0; i < round.length; i++) {
            expectSameReduction(
              round[i],
              reduceBlockExact(series().sampleAt, blocks[i].$1, blocks[i].$2),
            );
            if (snapshots.isNotEmpty && i < snapshots.first.length) {
              // Same block, different fill history: identical result.
              expectSameReduction(round[i], snapshots.first[i]);
            }
          }
          snapshots.add(round);
        }
      },
    );
  });

  group('windowedExtremes', () {
    BucketAccumulator ingest(List<int> all) {
      final acc = BucketAccumulator(bucketSize: bs, numBuckets: numBuckets);
      for (int i = 0; i < all.length; i++) {
        acc.add(i, all[i]);
      }
      return acc;
    }

    test('matches brute-force min/max over random windows', () {
      final all = randomData(134, 11);
      final acc = ingest(all);
      final rng = math.Random(12);
      for (int i = 0; i < 200; i++) {
        final start = 54 + rng.nextInt(70);
        final end = math.min(start + 1 + rng.nextInt(134 - start), 134);
        final ext = windowedExtremes(
          acc.series,
          start,
          end,
          (j) => all[j].toDouble(),
        );
        final window = all.sublist(start, end);
        expect(ext, isNotNull);
        expect(
          ext!.$1,
          window.reduce(math.min).toDouble(),
          reason: '[$start, $end) min',
        );
        expect(
          ext.$2,
          window.reduce(math.max).toDouble(),
          reason: '[$start, $end) max',
        );
      }
    });

    test('NaN samples are skipped on the scanned portions', () {
      final all = randomData(40, 13);
      final acc = ingest(all);
      // Small window (exact-scan fallback) with one NaN injected.
      final ext = windowedExtremes(
        acc.series,
        5,
        12,
        (j) => j == 7 ? double.nan : all[j].toDouble(),
      );
      final expected = [
        for (int j = 5; j < 12; j++)
          if (j != 7) all[j],
      ];
      expect(ext, isNotNull);
      expect(ext!.$1, expected.reduce(math.min).toDouble());
      expect(ext.$2, expected.reduce(math.max).toDouble());
    });

    test('returns null when no sample in the window yields a value', () {
      final acc = ingest(randomData(30, 14));
      expect(windowedExtremes(acc.series, 5, 8, (_) => double.nan), isNull);
    });
  });

  group('windowedDiffExtremes (gap-aware derivative axis)', () {
    /// Ingest `all` plus a gap list exactly as the live/session pipeline does:
    /// the diff accumulator takes [ingestDiff]'s synthetic-zero rule, and the
    /// exact evaluator suppresses the same samples with NaN.
    ({BucketSeries buckets, GapList gaps, double Function(int) sampleAt}) wire(
      List<int> all,
      List<(int, int)> gapRanges,
    ) {
      final acc = BucketAccumulator(bucketSize: bs, numBuckets: all.length);
      final gaps = GapList();
      for (final (s, e) in gapRanges) {
        gaps.append(s, e); // inputs must already be sorted/disjoint
      }
      for (int i = 0; i < all.length; i++) {
        acc.add(
          i,
          ingestDiff(
            sampleIndex: i,
            value: all[i],
            prevValue: i == 0 ? all[i] : all[i - 1],
            gaps: gaps,
          ),
        );
      }
      return (
        buckets: acc.series,
        gaps: gaps,
        // The painter's evaluator with an absolute index (it clamps j >= 1
        // upstream) and GraphDataSource.diffDefinedAt's rule.
        sampleAt: (j) => j >= 1 && !gaps.contains(j) && !gaps.contains(j - 1)
            ? (all[j] - all[j - 1]).toDouble()
            : double.nan,
      );
    }

    List<int> randomData(int n, int seed) {
      final rng = math.Random(seed);
      return List<int>.generate(n, (_) => rng.nextInt(2001) - 1000);
    }

    void expectExact(
      ({BucketSeries buckets, GapList gaps, double Function(int) sampleAt}) w,
      int start,
      int end, {
      required String label,
    }) {
      final ext = windowedDiffExtremes(
        w.buckets,
        start,
        end,
        w.sampleAt,
        w.gaps,
      );
      final expected = [
        for (int j = start; j < end; j++)
          if (w.sampleAt(j).isNaN) null else w.sampleAt(j),
      ].nonNulls.toList();
      if (expected.isEmpty) {
        expect(ext, isNull, reason: label);
        return;
      }
      expect(ext, isNotNull, reason: label);
      expect(ext!.$1, expected.reduce(math.min), reason: '$label min');
      expect(ext.$2, expected.reduce(math.max), reason: '$label max');
    }

    test('matches brute force with no gaps at all', () {
      final all = randomData(300, 31);
      final w = wire(all, const []);
      for (final (s, e) in [(0, 300), (0, 120), (50, 300), (120, 250)]) {
        expectExact(w, s, e, label: 'no gaps [$s, $e)');
      }
    });

    test('synthetic gap-edge zeros never widen the range', () {
      // Gap at 60: the diff at 60 and 61 is a synthetic zero, while the real
      // data is a slow ramp far from zero.
      final all = [for (int i = 0; i < 200; i++) 1000 + i * 7];
      final w = wire(all, const [(60, 61)]);
      final ext = windowedDiffExtremes(w.buckets, 0, 200, w.sampleAt, w.gaps);
      expect(ext, isNotNull);
      expect(ext!.$1, 7, reason: 'the flat synthetic zero must not appear');
      expect(ext.$2, 7);
      expectExact(w, 0, 200, label: 'single gap');
    });

    test('gap-heavy windows stay exact (dense-scan shortcut)', () {
      // 25 runs over 1000 samples: past one run per eighth of the window's
      // 100 buckets, so this drives the single-pass shortcut.
      final all = randomData(1000, 32);
      final w = wire(all, [for (int s = 40; s < 1000; s += 40) (s, s + 1)]);
      for (final (s, e) in [(0, 1000), (0, 500), (37, 863), (900, 1000)]) {
        expectExact(w, s, e, label: 'dense [$s, $e)');
      }
    });

    test('short gaps merge into runs without changing the result', () {
      // GapList merges adjacent appends, so these arrive as two ranges and
      // the synthetic expansion overlaps the next one.
      final all = randomData(120, 33);
      final w = wire(all, const [(10, 11), (11, 12), (12, 13), (60, 61)]);
      for (final (s, e) in [(0, 120), (0, 30), (5, 70)]) {
        expectExact(w, s, e, label: 'merged [$s, $e)');
      }
      expect(w.gaps.rangesIn(0, 120).toList(), [(10, 13), (60, 61)]);
    });

    test('the merged-run cursor never skips a later run', () {
      // Bucket-aligned runs: a cursor that advanced too far would fold a
      // later run's bucket instead of scanning it.
      final all = randomData(400, 34);
      final w = wire(all, [for (int s = 100; s < 400; s += 100) (s, s + 2)]);
      expectExact(w, 0, 400, label: 'cursor');
      expectExact(w, 380, 400, label: 'cursor tail');
    });

    test('a window wholly inside one gap has no drawn sample', () {
      final all = randomData(100, 35);
      final w = wire(all, const [(20, 60)]);
      expect(
        windowedDiffExtremes(w.buckets, 25, 55, w.sampleAt, w.gaps),
        isNull,
      );
    });
  });
}
