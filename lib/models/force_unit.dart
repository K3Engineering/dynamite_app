import 'calibration.dart';

/// Hardware AFE constants ([adcFullScaleV], [frontEndGain],
/// [adcCountsPerPolarity], [rawToMvMultiplier]) live in
/// models/calibration.dart — re-exported so existing importers keep working.
export 'calibration.dart'
    show adcFullScaleV, frontEndGain, adcCountsPerPolarity, rawToMvMultiplier;

/// Supported force and electrical display units.
///
/// Each value declares its conversion out of raw ADC counts as constructor
/// data: force units carry [kgfFactor] (1 kgf expressed in the unit) and
/// convert via the device calibration slope; electrical/raw units carry a
/// [fixedRawFactor] and ignore calibration. Exactly one of the two must be
/// set per value (enforced by the constructor assert).
enum ForceUnit {
  kN('kN', 'Kilonewtons', kgfFactor: 9.80665 / 1000),
  lbf('lbf', 'Pounds-force', kgfFactor: 2.20462),
  kgf('kgf', 'Kilogram-force', kgfFactor: 1.0),
  n('N', 'Newtons', kgfFactor: 9.80665),
  mV('mV', 'Raw Voltage', fixedRawFactor: rawToMvMultiplier),
  raw('Raw', 'ADC Counts', fixedRawFactor: 1.0);

  const ForceUnit(
    this.symbol,
    this.label, {
    this.kgfFactor,
    this.fixedRawFactor,
  }) : assert(
         (kgfFactor == null) != (fixedRawFactor == null),
         'declare exactly one conversion factor',
       );

  final String symbol;
  final String label;

  /// 1 kgf expressed in this unit (force units only).
  final double? kgfFactor;

  /// Fixed raw-counts -> unit multiplier (electrical/raw units only).
  final double? fixedRawFactor;

  /// Convert a raw ADC value to this unit, given the kgf/raw slope
  double fromRaw(double rawTared, double calibrationSlope) =>
      rawTared * multiplierFromRaw(calibrationSlope);

  /// Get the multiplier from raw ADC counts to this unit
  double multiplierFromRaw(double calibrationSlope) =>
      fixedRawFactor ?? calibrationSlope * kgfFactor!;

  /// Format a [value] (already in this unit) with an explicit sign, and a
  /// trailing [suffix] when given (e.g. the unit symbol).
  String _formatValue(double value, String suffix) {
    final sign = value < 0 ? '-' : '+';
    final decimals = this == ForceUnit.mV ? 4 : (this == ForceUnit.raw ? 0 : 3);
    final numStr = value.abs().toStringAsFixed(decimals);
    return suffix.isEmpty ? '$sign$numStr' : '$sign$numStr $suffix';
  }

  /// Format a [value] (already in this unit) with an explicit sign, without
  /// the unit suffix. Ideal for constrained layouts.
  String formatValueOnly(double value) => _formatValue(value, '');

  /// Format a value (already in this unit) for display.
  String format(double value) => _formatValue(value, symbol);
}
