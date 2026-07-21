/// Supported force and electrical display units.
enum ForceUnit {
  kN('kN', 'Kilonewtons'),
  lbf('lbf', 'Pounds-force'),
  kgf('kgf', 'Kilogram-force'),
  n('N', 'Newtons'),
  mV('mV', 'Raw Voltage'),
  raw('Raw', 'ADC Counts');

  const ForceUnit(this.symbol, this.label);
  final String symbol;
  final String label;

  /// Hardware constant for raw to mV conversion (1.2V Vref, 101x Gain, 24-bit bipolar ADC)
  static const double rawToMvMultiplier = (1.2 / 8388608.0 / 101.0) * 1000.0;

  double get _kgfMultiplier => switch (this) {
    ForceUnit.kgf => 1.0,
    ForceUnit.n => 9.80665,
    ForceUnit.kN => 9.80665 / 1000.0,
    ForceUnit.lbf => 2.20462,
    ForceUnit.mV => 1.0, // Fallback, not typically used
    ForceUnit.raw => 1.0, // Fallback, not typically used
  };

  /// Convert a raw ADC value to this unit, given the kgf/raw slope
  double fromRaw(double rawTared, double calibrationSlope) =>
      rawTared * multiplierFromRaw(calibrationSlope);

  /// Get the multiplier from raw ADC counts to this unit
  double multiplierFromRaw(double calibrationSlope) {
    if (this == ForceUnit.mV) {
      return rawToMvMultiplier;
    }
    if (this == ForceUnit.raw) {
      return 1.0;
    }
    return calibrationSlope * _kgfMultiplier;
  }

  /// Format a [value] (already in this unit) with an explicit sign, and a
  /// trailing [suffix] when given (e.g. the unit symbol). When [padded], the
  /// number is left-padded for column alignment in the stats table.
  String _formatValue(double value, String suffix, {bool padded = true}) {
    final sign = value < 0 ? '-' : '+';
    final decimals = this == ForceUnit.mV ? 4 : (this == ForceUnit.raw ? 0 : 3);
    var numStr = value.abs().toStringAsFixed(decimals);
    if (padded) {
      final padding = this == ForceUnit.mV
          ? 8
          : (this == ForceUnit.raw ? 6 : 7);
      numStr = numStr.padLeft(padding);
    }
    return suffix.isEmpty ? '$sign$numStr' : '$sign$numStr $suffix';
  }

  /// Format a [value] (already in this unit) with an explicit sign, without
  /// the unit suffix, and without extra padding. Ideal for constrained layouts.
  String formatValueOnly(double value) => _formatValue(value, '', padded: false);

  /// Format a value (already in this unit) for display.
  String format(double value) => _formatValue(value, symbol);
}
