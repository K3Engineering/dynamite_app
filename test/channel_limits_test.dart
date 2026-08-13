import 'package:dynamite_app/models/bucket_series.dart';
import 'package:dynamite_app/models/channel_limits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChannelLimits.isClipped', () {
    test('rails and interior', () {
      expect(ChannelLimits.isClipped(ChannelLimits.clipRawPos), isTrue);
      expect(ChannelLimits.isClipped(ChannelLimits.clipRawNeg), isTrue);
      expect(ChannelLimits.isClipped(0), isFalse);
      expect(ChannelLimits.isClipped(ChannelLimits.clipRawPos - 1), isFalse);
      expect(ChannelLimits.isClipped(ChannelLimits.clipRawNeg + 1), isFalse);
    });
  });

  group('hotIntervals', () {
    const pos = ChannelLimits.clipRawPos;
    const bs = kBucketSize;

    ({List<int> data, BucketSeries buckets}) ingest(List<int> values) {
      final acc = BucketAccumulator(
        bucketSize: bs,
        numBuckets: (values.length ~/ bs) + 2,
      );
      for (int i = 0; i < values.length; i++) {
        acc.add(i, values[i]);
      }
      return (data: values, buckets: acc.series);
    }

    List<({int start, int end})> run(
      List<int> values, {
      required bool treatMixedAsHot,
      int? start,
      int? end,
      bool positive = true,
      int threshold = pos,
    }) {
      final s = ingest(values);
      return hotIntervals(
        data: s.data,
        cap: s.data.length,
        buckets: s.buckets,
        start: start ?? 0,
        end: end ?? values.length,
        threshold: threshold,
        positive: positive,
        treatMixedAsHot: treatMixedAsHot,
      );
    }

    test('all cold is empty', () {
      expect(run(List.filled(4 * bs, 0), treatMixedAsHot: false), isEmpty);
    });

    test('all hot is one interval', () {
      expect(run(List.filled(4 * bs, pos), treatMixedAsHot: false), [
        (start: 0, end: 4 * bs),
      ]);
    });

    test('exact scan splits mixed buckets', () {
      final values = [for (int i = 0; i < 4 * bs; i++) i.isEven ? pos : 0];
      final its = run(values, treatMixedAsHot: false);
      expect(its.length, 2 * bs);
      expect(its.every((it) => it.end - it.start == 1), isTrue);
      expect(its.first, (start: 0, end: 1));
    });

    test('mixed-as-hot coalesces mixed buckets', () {
      final values = [for (int i = 0; i < 4 * bs; i++) i.isEven ? pos : 0];
      expect(run(values, treatMixedAsHot: true), [(start: 0, end: 4 * bs)]);
    });

    test('head stays exact when mixed-as-hot', () {
      final values = [for (int i = 0; i < 4 * bs; i++) i.isEven ? pos : 0];
      final its = run(values, treatMixedAsHot: true, start: 50);
      expect(its.last, (start: bs, end: 4 * bs));
      expect(its.sublist(0, its.length - 1), [
        for (int i = 50; i < bs; i += 2) (start: i, end: i + 1),
      ]);
    });

    test('negative rail', () {
      const neg = ChannelLimits.clipRawNeg;
      final values = [for (int i = 0; i < 2 * bs; i++) i.isEven ? neg : 0];
      expect(
        run(
          values,
          treatMixedAsHot: false,
          positive: false,
          threshold: neg,
        ).length,
        bs,
      );
      expect(
        run(values, treatMixedAsHot: true, positive: false, threshold: neg),
        [(start: 0, end: 2 * bs)],
      );
    });
  });
}
