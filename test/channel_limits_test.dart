import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/models/channel_limits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      expect(
        cal.rawFromMvV(-2.0),
        closeTo(-2 * testNominals.countsPerMvV, 1e-6),
      );
    });
  });

  group('ChannelLimits clip rails', () {
    test('clipDirFor: temporal rail state with direction', () {
      expect(ChannelLimits.clipDirFor(ChannelLimits.clipRawPos), 1);
      expect(ChannelLimits.clipDirFor(ChannelLimits.clipRawNeg), -1);
      expect(ChannelLimits.clipDirFor(0), 0);
      expect(ChannelLimits.clipDirFor(ChannelLimits.clipRawPos - 1), 0);
      expect(ChannelLimits.clipDirFor(ChannelLimits.clipRawNeg + 1), 0);
    });
  });
}
