import 'dart:math' as math;

import 'board_calibration.dart';
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

/// Supported force and electrical display units.
///
/// Conversion is per channel: a unit maps absolute raw ADC counts to the
/// display value net of tare via the channel's [ChannelCalibration] (the
/// board's piecewise map plus the assigned load cell). Force units are
/// unavailable — a null converter — for channels without an assigned load
/// cell; the UI shows '—' there. Without board constants only raw converts.
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

  /// The value of 1 ADC count in this unit on [channel]: the CSV export's
  /// fixed-point quantum (see `exportDecimalsFor` in csv_export.dart) and
  /// the derivative path's per-count scale (see [diffConverterFor]). Raw
  /// bypasses the board map, so its quantum is exactly 1 count. Null
  /// exactly when [converterFor] is (a force unit with no load cell
  /// assigned, or no resolved board constants).
  double? countQuantumFor(ChannelCalibration channel) {
    if (this == DisplayUnit.raw) return 1.0;
    final scale = _scalePerMvV(channel);
    final span = channel.board.sensitivityCountsPerMvV;
    return scale == null || span == null ? null : scale / span;
  }

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

  /// The multiplier applied to net mV/V for this unit on [channel]: force
  /// units fold in the cell's kgf-per-mV/V, mV folds in the nominal
  /// excitation (the board cal is ratiometric, so the mV rung rests on the
  /// nominal chain — the least-calibrated unit), mV/V is unity. Null when
  /// the unit is unavailable on the channel: a force unit with no load cell
  /// assigned, or ANY unit when the board's constants never resolved (raw
  /// counts only — see [BoardDataStatus]). Raw counts bypass the board map
  /// entirely and never consult this.
  double? _scalePerMvV(ChannelCalibration channel) {
    if (channel.board.nominals == null) return null;
    final f = kgfFactor;
    if (f != null) {
      final cell = channel.loadCell;
      return cell == null ? null : f * cell.kgfPerMvV;
    }
    return this == DisplayUnit.mV ? channel.board.nominals!.excitationV : 1.0;
  }

  /// Build the absolute-raw -> display-unit converter for one channel, net of
  /// [tare] (the board map is evaluated at both points and differenced, so
  /// piecewise nonlinearity applies on both sides). Monotone nondecreasing.
  /// Returns null when unavailable: a force unit on a channel with no
  /// assigned load cell.
  ///
  /// The returned closure is invoked per sample by the hot paths (graph
  /// reduction, stats), so the tare-side map value — loop-invariant — is
  /// evaluated once here instead of inside the closure.
  double Function(double raw)? converterFor(
    ChannelCalibration channel,
    double tare,
  ) {
    if (this == DisplayUnit.raw) return (raw) => raw - tare;
    final scale = _scalePerMvV(channel);
    if (scale == null) return null;
    final board = channel.board;
    final tareMvV = board.mvVFromRaw(tare);
    return (raw) => (board.mvVFromRaw(raw) - tareMvV) * scale;
  }

  /// Build the absolute-raw -> display-unit converter for one channel with no
  /// tare netting: the GROSS value at a raw point. Used to show where a tare
  /// sits (the tare is stored in counts; its display value is the map
  /// evaluated at that point). Null exactly when [converterFor] is.
  double Function(double raw)? grossConverterFor(ChannelCalibration channel) {
    if (this == DisplayUnit.raw) return (raw) => raw;
    final scale = _scalePerMvV(channel);
    if (scale == null) return null;
    final board = channel.board;
    return (raw) => board.mvVFromRaw(raw) * scale;
  }

  /// Inverse of [grossConverterFor]: the raw count at which the channel's
  /// gross map reads [value] in this unit. Manual tare entry stores counts,
  /// so a typed display value converts back through here. Null exactly when
  /// [grossConverterFor] is.
  double? rawFromGrossValue(ChannelCalibration channel, double value) {
    if (this == DisplayUnit.raw) return value;
    final scale = _scalePerMvV(channel);
    if (scale == null) return null;
    return channel.board.rawFromMvV(value / scale);
  }

  /// Build the raw-diff -> display-unit converter for one channel (no tare:
  /// offsets cancel in a difference). Uses the channel's terminal slope:
  /// the piecewise-local slope differs by ppm, and the derivative graph's
  /// bucket fast path needs a position-free map. Null exactly when
  /// [converterFor] is.
  double Function(double rawDiff)? diffConverterFor(
    ChannelCalibration channel,
  ) {
    final perCount = countQuantumFor(channel);
    if (perCount == null) return null;
    return (diff) => diff * perCount;
  }

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
