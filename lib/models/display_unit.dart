import 'dart:math' as math;

import 'channel_calibration.dart';

/// One rung of a unit's SI-prefix axis ladder: [factor] base units equal one
/// rung unit (1e-3 mV per µV, 1e3 kgf per tf); [symbol] is the axis-label
/// suffix for values expressed in the rung unit.
typedef AxisRung = ({double factor, String symbol});

/// The unit set a data source can convert right now: whether the board's
/// resolved constants exist (electrical and force units convert) and whether
/// any shown channel has a load cell assigned (force units convert).
/// Derived, never stored — the saved preference re-applies the moment
/// availability returns, and there is no secondary state to sync.
typedef UnitAvailability = ({bool boardHasNominals, bool anyActiveHasLoadCell});

/// Resolve the unit availability for a view showing [activeChannels], given
/// a per-channel calibration lookup. Board constants resolve all-or-nothing
/// and are uniform across channels, so channel 0 stands in for the board.
UnitAvailability resolveUnitAvailability(
  ChannelCalibration Function(int channel) calibrationFor,
  Iterable<int> activeChannels,
) => (
  boardHasNominals: calibrationFor(0).board.nominals != null,
  anyActiveHasLoadCell: activeChannels.any(
    (ch) => calibrationFor(ch).loadCell != null,
  ),
);

/// Supported force and electrical display units: presentation metadata
/// (symbol, axis ladder, force factor, formatting). Conversion itself is
/// calibration-side — see `ChannelConverter`, which binds a channel's
/// [ChannelCalibration] to its tare offset. Force units are unavailable
/// for channels without an assigned load cell; the UI shows '—' there.
/// Without board constants only raw converts.
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

  /// SI-prefix ladder for graph axis labels, coarsest-first. Only the rungs
  /// a window can plausibly need: descending toward the noise floor, plus
  /// the audience's named larger units (tf, kN). Magnitudes beyond the
  /// coarsest rung just grow digits ("5000 kgf"); magnitudes below the
  /// finest clamp to it.
  final List<AxisRung> axisLadder;

  /// The axis-label rung for a window whose largest label magnitude is
  /// [maxMagnitude] in this unit: the coarsest ladder rung keeping scaled
  /// magnitudes >= 1, so tick labels stay in a 1..1000 band. Sub-rung
  /// magnitudes (and zero) fall through to the finest rung. Axis labels are
  /// drawn per frame (never baked into segment textures), so a rung flip as
  /// the window breathes costs a relabel only.
  AxisRung axisRung(double maxMagnitude) {
    for (final rung in axisLadder) {
      if (maxMagnitude / rung.factor >= 1) return rung;
    }
    return axisLadder.last;
  }

  /// Decimals for axis tick labels with tick step [tickStep] (already in
  /// rung units): exactly enough digits to resolve the 1/2/5 x 10^k step
  /// (ticks are integer multiples of the step, so its least significant
  /// digit is all they ever print). The nudge keeps an exact power-of-ten
  /// step from gaining a spurious decimal to floating-point error in the
  /// log.
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

  /// Force units need an assigned load cell; electrical units only need the
  /// board calibration. Drives the Settings picker's grouping.
  bool get isForce => kgfFactor != null;

  /// Whether this unit can convert under [availability]: raw always can;
  /// electrical units need board constants; force units also need a load
  /// cell on a shown channel.
  bool isAvailable(UnitAvailability availability) {
    if (this == DisplayUnit.raw) return true;
    if (!availability.boardHasNominals) return false;
    return !isForce || availability.anyActiveHasLoadCell;
  }

  /// The unit the instrument actually draws under [availability]: this unit
  /// when available, else the first available rung down the ladder. The
  /// preference is not written; the saved unit re-applies as soon as it is
  /// available again.
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

  /// Format a [value] (already in this unit) with an explicit sign, without
  /// the unit suffix. Ideal for constrained layouts.
  String formatValueOnly(double value) => _formatValue(value, '');

  /// Format a value (already in this unit) for display.
  String format(double value) => _formatValue(value, symbol);
}
