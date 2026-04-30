/// Supported force and electrical display units.
enum ForceUnit {
  kN('kN', 'Kilonewtons', true),
  lbf('lbf', 'Pounds-force', true),
  kgf('kgf', 'Kilogram-force', true),
  n('N', 'Newtons', true),
  mV('mV', 'Raw Voltage', false);

  const ForceUnit(this.symbol, this.label, this.isForce);
  final String symbol;
  final String label;
  final bool isForce;

  /// Hardware constant for raw to mV conversion (1.2V Vref, 101x Gain, 24-bit bipolar ADC)
  static const double rawToMvMultiplier = (1.2 / 8388608.0 / 101.0) * 1000.0;

  double get _kgfMultiplier => switch (this) {
        ForceUnit.kgf => 1.0,
        ForceUnit.n => 9.80665,
        ForceUnit.kN => 9.80665 / 1000.0,
        ForceUnit.lbf => 2.20462,
        ForceUnit.mV => 1.0, // Fallback, not typically used
      };

  /// Convert a value in kgf (the device's native calibrated unit) to this unit.
  double fromKgf(double kgf) => kgf * _kgfMultiplier;

  /// Convert a raw ADC value to this unit, given the kgf/raw slope
  double fromRaw(double rawTared, double calibrationSlope) {
    if (this == ForceUnit.mV) {
      return rawTared * rawToMvMultiplier;
    }
    return rawTared * calibrationSlope * _kgfMultiplier;
  }

  /// Get the multiplier from raw ADC counts to this unit
  double multiplierFromRaw(double calibrationSlope) {
    if (this == ForceUnit.mV) {
      return rawToMvMultiplier;
    }
    return calibrationSlope * _kgfMultiplier;
  }

  /// Format a value (already in this unit) for display.
  String format(double value) {
    /// a minus sign doesn't need to be added explicitly
    final sign = value < 0 ? '-' : '+';
    final decimals = this == ForceUnit.mV ? 4 : 3;
    final padding = this == ForceUnit.mV ? 8 : 7;
    final numStr = value.abs().toStringAsFixed(decimals).padLeft(padding);
    return '$sign$numStr $symbol';
  }

  /// Format a rate of change (derivative) in this unit for display.
  String formatRate(double value) {
    final sign = value < 0 ? '-' : '+';
    final decimals = this == ForceUnit.mV ? 4 : 3;
    final padding = this == ForceUnit.mV ? 8 : 7;
    final numStr = value.abs().toStringAsFixed(decimals).padLeft(padding);
    return '$sign$numStr $symbol/s';
  }
}
