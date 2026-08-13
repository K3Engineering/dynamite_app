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

  const fraction = 0.8;

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
      expect(cal.rawFromMvV(-2.0), closeTo(-2 * testNominals.countsPerMvV, 1e-6));
    });
  });

  group('ChannelLimits without a load cell (clip only)', () {
    final limits = ChannelLimits(board: ChannelBoardCalibration());

    test('no load-cell anchors', () {
      expect(limits.lcFsRawPos, isNull);
      expect(limits.lcFsRawNeg, isNull);
    });

    test('ok in mid-range', () {
      expect(limits.levelForRaw(0, fraction), LimitLevel.ok);
      expect(limits.levelForRaw(1000000, fraction), LimitLevel.ok);
      expect(limits.levelForRaw(-1000000, fraction), LimitLevel.ok);
    });

    test('caution past the warn fraction of the half-scale, both sides', () {
      final edge = (fraction * adcCountsPerPolarity).round();
      expect(limits.levelForRaw(edge + 100, fraction), LimitLevel.caution);
      expect(limits.levelForRaw(-edge - 100, fraction), LimitLevel.caution);
      expect(limits.levelForRaw(edge - 100, fraction), LimitLevel.ok);
    });

    test('exceeded exactly at the rails', () {
      expect(
        limits.levelForRaw(ChannelLimits.clipRawPos, fraction),
        LimitLevel.exceeded,
      );
      expect(
        limits.levelForRaw(ChannelLimits.clipRawNeg, fraction),
        LimitLevel.exceeded,
      );
    });

    test('clipDirFor: temporal rail state with direction', () {
      expect(ChannelLimits.clipDirFor(ChannelLimits.clipRawPos), 1);
      expect(ChannelLimits.clipDirFor(ChannelLimits.clipRawNeg), -1);
      expect(ChannelLimits.clipDirFor(0), 0);
      expect(ChannelLimits.clipDirFor(ChannelLimits.clipRawPos - 1), 0);
      expect(ChannelLimits.clipDirFor(ChannelLimits.clipRawNeg + 1), 0);
    });
  });

  group('ChannelLimits with a load cell (nominal board)', () {
    // 1.0 mV/V cell: FS anchors sit well inside the ADC range (~3.2M counts
    // vs ~8.39M), so the cell rating binds first.
    final limits = ChannelLimits(
      board: ChannelBoardCalibration(nominals: testNominals),
      loadCellFsMvV: 1.0,
    );

    test('FS anchors are the rating inverted through the board map', () {
      expect(limits.lcFsRawPos!, closeTo(testNominals.countsPerMvV, 1e-6));
      expect(limits.lcFsRawNeg!, closeTo(-testNominals.countsPerMvV, 1e-6));
    });

    test('levels follow the absolute raw value (no tare involved)', () {
      final fsPos = limits.lcFsRawPos!;
      final cautionPos = (fraction * fsPos).round();
      expect(limits.levelForRaw(0, fraction), LimitLevel.ok);
      expect(limits.levelForRaw(cautionPos - 100, fraction), LimitLevel.ok);
      expect(
        limits.levelForRaw(cautionPos + 100, fraction),
        LimitLevel.caution,
      );
      expect(
        limits.levelForRaw(-cautionPos - 100, fraction),
        LimitLevel.caution,
      );
      expect(
        limits.levelForRaw(fsPos.round() + 100, fraction),
        LimitLevel.exceeded,
      );
      expect(
        limits.levelForRaw(-fsPos.round() - 100, fraction),
        LimitLevel.exceeded,
      );
    });

    test('the ADC rail still bounds a cell rated within range', () {
      expect(
        limits.levelForRaw(ChannelLimits.clipRawPos, fraction),
        LimitLevel.exceeded,
      );
    });
  });

  group('ChannelLimits with a cell rated beyond the rail', () {
    // A 3 mV/V cell on the nominal chain: FS anchors (~9.6M counts) lie
    // OUTSIDE the ADC range (~8.39M), so clipping binds before the rating.
    final limits = ChannelLimits(
      board: ChannelBoardCalibration(nominals: testNominals),
      loadCellFsMvV: 3.0,
    );

    test('FS anchors sit past the rails', () {
      expect(limits.lcFsRawPos!, greaterThan(ChannelLimits.clipRawPos));
      expect(limits.lcFsRawNeg!, lessThan(ChannelLimits.clipRawNeg));
    });

    test('rungs clamp to the rail when the rating cannot be reached', () {
      // The warning rung anchors to the cell ladder (0.8 x FS = 7.68M
      // counts), not to the ADC range — with a cell assigned, the fraction
      // is of the CELL's rating.
      final cautionPos = testNominals.countsPerMvV * 3.0 * fraction;
      expect(limits.levelForRaw(cautionPos.round() + 100, fraction),
          LimitLevel.caution);
      expect(limits.levelForRaw(cautionPos.round() - 100, fraction),
          LimitLevel.ok);
      expect(
        limits.levelForRaw(ChannelLimits.clipRawPos, fraction),
        LimitLevel.exceeded,
      );
      // The limit rung lies past the rail and clamps to it.
      final anchors = limits.anchorsFor(true, fraction);
      expect(anchors.limit, ChannelLimits.clipRawPos.toDouble());
      expect(anchors.warn, closeTo(cautionPos, 1e-6));
    });
  });

  group('ChannelLimits with the warning set past full scale', () {
    // 1 mV/V cell, setting 200%: the roles swap — FSR warns ("out of
    // spec"), 2x FSR limits. Both rungs are reachable on the nominal chain
    // (2x FS ~ 6.4M counts < 8.39M rail).
    final limits = ChannelLimits(
      board: ChannelBoardCalibration(nominals: testNominals),
      loadCellFsMvV: 1.0,
    );

    test('anchors swap roles across the FSR detent', () {
      final anchors = limits.anchorsFor(true, 2.0);
      expect(anchors.warn, closeTo(testNominals.countsPerMvV, 1e-6));
      expect(anchors.limit, closeTo(2 * testNominals.countsPerMvV, 1e-6));
      final neg = limits.anchorsFor(false, 2.0);
      expect(neg.warn, closeTo(-testNominals.countsPerMvV, 1e-6));
      expect(neg.limit, closeTo(-2 * testNominals.countsPerMvV, 1e-6));
    });

    test('past the rating is caution, past the setting is exceeded', () {
      final fs = testNominals.countsPerMvV;
      expect(limits.levelForRaw((0.5 * fs).round(), 2.0), LimitLevel.ok);
      expect(limits.levelForRaw((1.5 * fs).round(), 2.0), LimitLevel.caution);
      expect(limits.levelForRaw(-(1.5 * fs).round(), 2.0), LimitLevel.caution);
      expect(limits.levelForRaw((2.5 * fs).round(), 2.0), LimitLevel.exceeded);
    });

    test('a limit rung past the rail clamps to the rail', () {
      // 3 mV/V cell at 200%: both rungs lie past the rail, so no warning
      // band remains — only the clip.
      final wide = ChannelLimits(
        board: ChannelBoardCalibration(nominals: testNominals),
        loadCellFsMvV: 3.0,
      );
      final anchors = wide.anchorsFor(true, 2.0);
      expect(anchors.warn, ChannelLimits.clipRawPos.toDouble());
      expect(anchors.limit, ChannelLimits.clipRawPos.toDouble());
      expect(
        wide.levelForRaw((0.95 * ChannelLimits.clipRawPos).round(), 2.0),
        LimitLevel.ok,
      );
    });

    test('no cell: a setting past 100% leaves no warning band', () {
      final clipOnly = ChannelLimits(board: ChannelBoardCalibration());
      expect(
        clipOnly.levelForRaw((0.9 * adcCountsPerPolarity).round(), 2.0),
        LimitLevel.ok,
      );
      expect(
        clipOnly.levelForRaw(ChannelLimits.clipRawPos, 2.0),
        LimitLevel.exceeded,
      );
    });

    test('a 100% setting degenerates the band to nothing', () {
      final fs = testNominals.countsPerMvV;
      final anchors = limits.anchorsFor(true, 1.0);
      expect(anchors.warn, anchors.limit);
      expect(limits.levelForRaw((0.95 * fs).round(), 1.0), LimitLevel.ok);
      expect(limits.levelForRaw((1.05 * fs).round(), 1.0),
          LimitLevel.exceeded);
    });
  });

  group('ChannelLimits with a factory-calibrated board', () {
    // Same affine fixture: raw = alpha + beta * mvV. The absolute anchors
    // must include the offset (alpha): 1.0 mV/V of absolute output is NOT
    // beta counts from zero.
    const alpha = 412.7;
    const beta = 3198500.0;
    final sp = ladderSetpointsMvV(nominalLadderResistors);
    final cal = ChannelBoardCalibration(
      readings: [for (final d in sp) alpha + beta * d],
    );
    final limits = ChannelLimits(board: cal, loadCellFsMvV: 1.0);

    test('FS anchors include the board offset', () {
      expect(limits.lcFsRawPos!, closeTo(alpha + beta * 1.0, 0.01));
      expect(limits.lcFsRawNeg!, closeTo(alpha - beta * 1.0, 0.01));
    });

    test('levels evaluate against the offset anchors', () {
      expect(limits.levelForRaw(alpha.round(), fraction), LimitLevel.ok);
      expect(
        limits.levelForRaw((alpha + beta).round() + 100, fraction),
        LimitLevel.exceeded,
      );
      expect(
        limits.levelForRaw((alpha - beta).round() - 100, fraction),
        LimitLevel.exceeded,
      );
    });
  });
}
