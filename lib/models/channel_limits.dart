import 'board_calibration.dart';

/// ADC-rail clip checks. Clipping is a property of the 24-bit converter:
/// +/-2^23 counts, regardless of tare, display unit, or front-end gain.
class ChannelLimits {
  static const int clipRawPos = adcCountsPerPolarity - 1;
  static const int clipRawNeg = -adcCountsPerPolarity;

  static bool isClipped(int raw) => raw >= clipRawPos || raw <= clipRawNeg;
}
