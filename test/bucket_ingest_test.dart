import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/bucket_series.dart';
import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/models/gap_list.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/session_storage.dart';

/// Locks the live/session ingest mirror: DataHub's streaming ingest and
/// SessionData's load-time pass must produce byte-identical value and diff
/// buckets for the same sample stream (including gaps), because the
/// renderers treat the two sources interchangeably.
void main() {
  group('ingestDiff', () {
    final gaps = GapList()..append(10, 20);

    test('is 0 for the very first sample', () {
      expect(
        ingestDiff(sampleIndex: 0, value: 123, prevValue: 999, gaps: gaps),
        0,
      );
    });

    test('is the first difference for ordinary samples', () {
      expect(
        ingestDiff(sampleIndex: 5, value: 123, prevValue: 100, gaps: gaps),
        23,
      );
    });

    test('is 0 at the gap-exit sample (jump spans the gap)', () {
      // Sample 20 is the first real sample after the gap [10, 20).
      expect(
        ingestDiff(sampleIndex: 20, value: 5000, prevValue: 100, gaps: gaps),
        0,
      );
    });

    test('is 0 inside a gap by construction (held - held)', () {
      // Inside the gap the caller feeds the held value as both value and
      // prevValue, so the rule and the arithmetic agree.
      expect(
        ingestDiff(sampleIndex: 15, value: 100, prevValue: 100, gaps: gaps),
        0,
      );
    });
  });

  group('BucketAccumulator', () {
    test('reset-or-fold matches a brute-force reference', () {
      final rng = math.Random(7);
      const bs = 10;
      const numBuckets = 8;
      final acc = BucketAccumulator(bucketSize: bs, numBuckets: numBuckets);
      const n = 134; // wraps the 80-sample ring, ends mid-bucket
      final all = List<int>.generate(n, (_) => rng.nextInt(2001) - 1000);
      for (int i = 0; i < n; i++) {
        acc.add(i, all[i]);
      }

      final s = acc.series;
      expect(s.samples, n);

      // Every bucket index whose slot has not been overwritten must hold the
      // exact aggregates of its samples.
      const int bNow = (n - 1) ~/ bs;
      for (int b = math.max(0, bNow - numBuckets + 1); b <= bNow; b++) {
        final from = b * bs;
        final to = math.min((b + 1) * bs, n);
        final expected = all.sublist(from, to);
        final li = b % numBuckets;
        expect(s.mins[li], expected.reduce(math.min), reason: 'bucket $b min');
        expect(s.maxs[li], expected.reduce(math.max), reason: 'bucket $b max');
        expect(
          s.sums[li],
          expected.reduce((a, x) => a + x),
          reason: 'bucket $b sum',
        );
      }
    });

    test('reset restarts ingest from sample 0', () {
      final acc = BucketAccumulator(bucketSize: 10, numBuckets: 4);
      acc.add(0, 5);
      acc.add(1, 7);
      acc.reset();
      expect(acc.series.samples, 0);
      acc.add(0, -3); // would assert if ingest were not restarted
      expect(acc.series.samples, 1);
      expect(acc.series.mins[0], -3);
    });
  });

  group('DataHub vs SessionData bucket mirror', () {
    test('same stream (with gaps) produces identical buckets', () {
      const int n = 12345;
      const int channels = DataHub.numAdcChannels;
      final rng = math.Random(42);

      final hub = DataHub();
      final recorded = List.generate(channels, (_) => Int32List(n));
      final lastVal = List<int>.filled(channels, 0);
      final frame = Int32List(channels);

      while (hub.totalSamples < n) {
        final t = hub.totalSamples;
        // A few dropped ranges at fixed points in the stream.
        if (t == 500 || t == 5000 || t == 9999) {
          final count = 30 + rng.nextInt(200);
          hub.addDroppedFrames(count);
          for (int d = 0; d < count && t + d < n; d++) {
            for (int ch = 0; ch < channels; ch++) {
              recorded[ch][t + d] = lastVal[ch]; // held value
            }
          }
          continue;
        }
        for (int ch = 0; ch < channels; ch++) {
          final v = (ch + 1) * 1000 + rng.nextInt(20001) - 10000;
          frame[ch] = v;
          lastVal[ch] = v;
          recorded[ch][t] = v;
        }
        hub.addSampleFrame(frame);
      }
      expect(hub.totalSamples, n);

      final sess = SessionData(
        channels: recorded,
        sampleRate: DataHub.samplesPerSec,
        sampleCount: n,
        calibrations: [
          for (int ch = 0; ch < channels; ch++)
            ChannelCalibration(board: ChannelBoardCalibration()),
        ],
        tares: List.filled(channels, 0.0),
        gaps: GapList.fromJson(hub.gaps.toJson()),
      );

      final int sessBuckets = ((n - 1) ~/ sess.bucketSize) + 1;
      for (int ch = 0; ch < channels; ch++) {
        final hubVal = hub.valueBuckets[ch].series;
        final hubDiff = hub.diffBuckets[ch].series;
        final sessVal = sess.valueBuckets[ch].series;
        final sessDiff = sess.diffBuckets[ch].series;

        expect(hubVal.samples, n);
        expect(sessVal.samples, n);
        expect(hubVal.bucketSize, sessVal.bucketSize);

        // n << hub capacity, so hub slot index == absolute bucket index.
        for (int b = 0; b < sessBuckets; b++) {
          expect(hubVal.mins[b], sessVal.mins[b], reason: 'ch $ch val min $b');
          expect(hubVal.maxs[b], sessVal.maxs[b], reason: 'ch $ch val max $b');
          expect(hubVal.sums[b], sessVal.sums[b], reason: 'ch $ch val sum $b');
          expect(
            hubDiff.mins[b],
            sessDiff.mins[b],
            reason: 'ch $ch dif min $b',
          );
          expect(
            hubDiff.maxs[b],
            sessDiff.maxs[b],
            reason: 'ch $ch dif max $b',
          );
          expect(
            hubDiff.sums[b],
            sessDiff.sums[b],
            reason: 'ch $ch dif sum $b',
          );
        }
      }
    });

    test('gap-exit jump is suppressed in the diff buckets on both sides', () {
      const int channels = DataHub.numAdcChannels;
      final hub = DataHub();
      final frame = Int32List(channels);

      void feed(int value, int count) {
        for (int i = 0; i < count; i++) {
          frame.fillRange(0, channels, value);
          hub.addSampleFrame(frame);
        }
      }

      feed(100, 150); // constant before the gap
      hub.addDroppedFrames(50); // held at 100
      feed(5000, 150); // constant after: only the gap-exit sample jumps
      final int n = hub.totalSamples;

      final recorded = List.generate(channels, (_) {
        final line = Int32List(n);
        line.fillRange(0, 200, 100); // 150 real + 50 held
        line.fillRange(200, n, 5000);
        return line;
      });
      final sess = SessionData(
        channels: recorded,
        sampleRate: DataHub.samplesPerSec,
        sampleCount: n,
        calibrations: [
          for (int ch = 0; ch < channels; ch++)
            ChannelCalibration(board: ChannelBoardCalibration()),
        ],
        tares: List.filled(channels, 0.0),
        gaps: GapList.fromJson(hub.gaps.toJson()),
      );

      // Constant segments + suppressed gap-exit diff => every diff bucket is
      // exactly zero everywhere, despite the 100 -> 5000 jump.
      final int buckets = ((n - 1) ~/ 100) + 1;
      for (final acc in [hub.diffBuckets[0], sess.diffBuckets[0]]) {
        final s = acc.series;
        for (int b = 0; b < buckets; b++) {
          expect(s.mins[b], 0, reason: 'diff min bucket $b');
          expect(s.maxs[b], 0, reason: 'diff max bucket $b');
          expect(s.sums[b], 0, reason: 'diff sum bucket $b');
        }
      }
    });
  });
}
