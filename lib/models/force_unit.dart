/// Supported force display units.
enum ForceUnit {
  kN('kN', 'Kilonewtons'),
  lbf('lbf', 'Pounds-force'),
  kgf('kgf', 'Kilogram-force'),
  n('N', 'Newtons');

  const ForceUnit(this.symbol, this.label);
  final String symbol;
  final String label;

  /// Convert a value in kgf (the device's native calibrated unit) to this unit.
  double fromKgf(double kgf) => switch (this) {
    ForceUnit.kgf => kgf,
    ForceUnit.n => kgf * 9.80665,
    ForceUnit.kN => kgf * 9.80665 / 1000.0,
    ForceUnit.lbf => kgf * 2.20462,
  };

  /// Format a value (already in this unit) for display.
  String format(double value) {
    /// a minus sign doesn't need to be added explicitly
    final sign = value < 0 ? '-' : '+';
    // Max value < 1000 is 999.999 (7 chars: 3 digits + 1 dot + 3 decimals)
    final numStr = value.abs().toStringAsFixed(3).padLeft(7);
    return '$sign$numStr $symbol';
  }
}
