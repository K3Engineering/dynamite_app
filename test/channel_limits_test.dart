import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/models/channel_limits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fraction = 0.8;

  // Nominal chain for boards without factory data: the app's former compiled
  // constants (1.2 V reference, x101 AFE, unity PGA, 4.53 V excitation).
  const testNominals = ChannelNominals(
    adcFsrV: 1.2,
    afeGain: 101,
    pgaGain: 1,
    excitationV: 4.53,
  );

  group('ChannelBoardCalibration.rawFromMvV', () {
    // A perfect affine device (same fixture shape as calibration_test):
    // raw = alpha + beta * setpoint.
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

    test('clip warnings fire where the cell rating cannot be reached', () {
      final edge = (fraction * adcCountsPerPolarity).round();
      expect(limits.levelForRaw(edge + 100, fraction), LimitLevel.caution);
      expect(
        limits.levelForRaw(ChannelLimits.clipRawPos, fraction),
        LimitLevel.exceeded,
      );
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
