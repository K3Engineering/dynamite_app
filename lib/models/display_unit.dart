import 'dart:math' as math;

import 'channel_calibration.dart';
import 'device_profile.dart';

/// One rung of a unit's SI-prefix axis ladder: [factor] base units equal one
/// rung unit (1e-3 mV per µV, 1e3 kgf per tf); [symbol] is the axis-label
/// suffix for values expressed in the rung unit.
typedef AxisRung = ({double factor, String symbol});

/// Whether the board's resolved constants exist and any channel carries a load
/// cell — i.e. which units a data source can convert right now.
typedef UnitAvailability = ({
  bool boardHasNominals,
  bool anyChannelHasLoadCell,
});

/// Resolve availability for the calibration set behind [calibrationFor]. Board
/// data is all-or-nothing per board, so channel 0 stands in for it. Channel
/// visibility is not an input.
UnitAvailability resolveUnitAvailability(
  ChannelCalibration Function(int channel) calibrationFor,
) => (
  boardHasNominals: calibrationFor(0).board != null,
  anyChannelHasLoadCell: [
    for (int i = 0; i < kAdcChannelCount; i++)
      if (calibrationFor(i).loadCell != null) i,
  ].isNotEmpty,
);

/// Supported force and electrical display units: presentation metadata only;
/// conversion is calibration-side (see `ChannelConverter`).
enum DisplayUnit {
  kN(
    'kN',
    'Kilonewtons',
    kgfFactor: 9.80665 / 1000,
    axisLadder: [
      (factor: 1.0, symbol: 'kN'),
      (factor: 1e-3, symbol: 'N'),
      (factor: 1e-6, symbol: 'mN'),
    ],
  ),
  lbf(
    'lbf',
    'Pounds-force',
    kgfFactor: 2.20462,
    // Decimal lbf is the convention (no ozf rung).
    axisLadder: [(factor: 1.0, symbol: 'lbf')],
  ),
  kgf(
    'kgf',
    'Kilogram-force',
    kgfFactor: 1.0,
    axisLadder: [
      (factor: 1e3, symbol: 'tf'),
      (factor: 1.0, symbol: 'kgf'),
      (factor: 1e-3, symbol: 'gf'),
    ],
  ),
  n(
    'N',
    'Newtons',
    kgfFactor: 9.80665,
    axisLadder: [
      (factor: 1e3, symbol: 'kN'),
      (factor: 1.0, symbol: 'N'),
      (factor: 1e-3, symbol: 'mN'),
    ],
  ),
  mVv(
    'mV/V',
    'Cell output ratio',
    axisLadder: [
      (factor: 1.0, symbol: 'mV/V'),
      (factor: 1e-3, symbol: 'µV/V'),
      (factor: 1e-6, symbol: 'nV/V'),
    ],
  ),
  mV(
    'mV',
    'Cell output voltage',
    axisLadder: [
      (factor: 1.0, symbol: 'mV'),
      (factor: 1e-3, symbol: 'µV'),
      (factor: 1e-6, symbol: 'nV'),
    ],
  ),
  raw('Raw', 'ADC Counts', axisLadder: [(factor: 1.0, symbol: 'Raw')]);

  const DisplayUnit(
    this.symbol,
    this.label, {
    this.kgfFactor,
    required this.axisLadder,
  });

  final String symbol;
  final String label;

  /// 1 kgf expressed in this unit (force units only); null for electrical
  /// units, which convert through the board calibration alone.
  final double? kgfFactor;

  /// SI-prefix ladder for axis labels, coarsest-first (the rungs a window can
  /// plausibly need). Magnitudes beyond the coarsest just grow digits; below
  /// the finest clamp to it.
  final List<AxisRung> axisLadder;

  /// The coarsest rung keeping scaled magnitudes >= 1, so labels stay in a
  /// 1..1000 band; sub-rung magnitudes and zero fall to the finest rung.
  AxisRung axisRung(double maxMagnitude) {
    for (final rung in axisLadder) {
      if (maxMagnitude / rung.factor >= 1) return rung;
    }
    return axisLadder.last;
  }

  /// Decimals needed to resolve the 1/2/5 x 10^k tick step [tickStep] (in rung
  /// units); the nudge absorbs floating-point error in the log.
  static int axisDecimalsFor(double tickStep) =>
      math.max(0, -(math.log(tickStep) / math.ln10 + 1e-9).floor());

  /// Parse a stored [DisplayUnit.name] (a preference, a session row) back to
  /// its value; an unrecognizable or missing value falls back to [fallback]
  /// (the platform default unit).
  static DisplayUnit fromName(
    String? name, [
    DisplayUnit fallback = DisplayUnit.mVv,
  ]) => DisplayUnit.values.firstWhere(
    (u) => u.name == name,
    orElse: () => fallback,
  );

  /// True for the force units (which fold in the load cell).
  bool get isForce => kgfFactor != null;

  /// Raw always; electrical units need board constants; force units also need
  /// a load cell on some channel.
  bool isAvailable(UnitAvailability availability) {
    if (this == DisplayUnit.raw) return true;
    if (!availability.boardHasNominals) return false;
    return !isForce || availability.anyChannelHasLoadCell;
  }

  /// This unit when available under [availability], else the first available
  /// fallback. The saved preference is not written.
  DisplayUnit effective(UnitAvailability availability) => [
    this,
    DisplayUnit.mVv,
    DisplayUnit.raw,
  ].firstWhere((u) => u.isAvailable(availability));

  /// Format a [value] (already in this unit) with an explicit sign, and a
  /// trailing [suffix] when given (e.g. the unit symbol).
  String _formatValue(double value, String suffix) {
    final sign = value < 0 ? '-' : '+';
    final decimals = switch (this) {
      DisplayUnit.raw => 0,
      DisplayUnit.mV || DisplayUnit.mVv => 4,
      _ => 3,
    };
    final numStr = value.abs().toStringAsFixed(decimals);
    return suffix.isEmpty ? '$sign$numStr' : '$sign$numStr $suffix';
  }

  /// Like [format], without the unit suffix.
  String formatValueOnly(double value) => _formatValue(value, '');

  /// Format [value] (already in this unit) with the unit symbol.
  String format(double value) => _formatValue(value, symbol);
}
