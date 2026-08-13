import 'calibration.dart';

/// Temporal ADC-rail state of one raw sample.
///
/// Clipping is a property of the 24-bit converter: +/-2^23 counts,
/// regardless of tare, display unit, or front-end gain. Deliberately
/// stateless — the clip indication exists only while the signal sits at
/// the rail (no latching).
class ChannelLimits {
  /// Raw counts of the positive ADC rail (0x7FFFFF): a sample AT or above
  /// this is clipped.
  static const int clipRawPos = adcCountsPerPolarity - 1;

  /// Raw counts of the negative ADC rail (-0x800000): a sample AT or below
  /// this is clipped.
  static const int clipRawNeg = -adcCountsPerPolarity;

  /// Temporal rail state of one raw sample: +1 at/above the positive ADC
  /// rail, -1 at/below the negative rail, 0 otherwise. The clip icon's
  /// direction is the sign of this value (which the pegged display number
  /// also carries).
  static int clipDirFor(int raw) => raw >= clipRawPos
      ? 1
      : raw <= clipRawNeg
      ? -1
      : 0;
}
