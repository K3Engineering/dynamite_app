import 'package:dynamite_app/models/bucket_series.dart';
import 'package:dynamite_app/models/calibration.dart';
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

  const testNominals = ChannelNominals(
    adcFsrV: 1.2,
    afeGain: 101,
    pgaGain: 1,
    excitationV: 4.53,
  );

  group('ChannelBoardCalibration.rawFromMvV', () {
    const alpha = 412.7;
    const beta = 3198500.0;
    final sp = ladderSetpointsMvV(nominalLadderResistors);
    final readings = [for (final d in sp) alpha + beta * d];
    final cal = ChannelBoardCalibration(readings: readings);

    test('anchors exactly at every cal point', () {
      for (int k = 0; k < kCalPointCount; ++k) {
        expect(cal.rawFromMvV(sp[k]), closeTo(readings[k], 1e-6));
      }
    });

    test('round-trips mvVFromRaw across the whole ADC range', () {
      for (final raw in [-8388607.0, -1e6, alpha, 2e6, 8388607.0]) {
        expect(cal.rawFromMvV(cal.mvVFromRaw(raw)), closeTo(raw, 0.01));
      }
    });

    test('round-trips rawFromMvV across the setpoint range', () {
      for (final mvV in [-1.9, -0.5, 0.0, 1.3, 1.99]) {
        expect(cal.mvVFromRaw(cal.rawFromMvV(mvV)), closeTo(mvV, 1e-9));
      }
    });

    test('nominal board uses the nominal chain', () {
      final cal = ChannelBoardCalibration(nominals: testNominals);
      expect(cal.rawFromMvV(1.0), closeTo(testNominals.countsPerMvV, 1e-6));
      expect(
        cal.rawFromMvV(-2.0),
        closeTo(-2 * testNominals.countsPerMvV, 1e-6),
      );
    });
  });
}
