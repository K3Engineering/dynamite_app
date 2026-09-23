import 'board_calibration.dart';
import 'channel_calibration.dart';
import 'display_unit.dart';

/// One channel's conversion between raw ADC counts and display values: its
/// calibration bound to a tare offset (raw counts, null = no offset). Units
/// are presentation units — everything that knows the hardware (the board
/// map, the cell scale, the mV anchor) lives on the calibration side; a
/// [DisplayUnit] contributes only its factor and formatting.
///
/// Tare-zero invariant: [net] at the tare point is exactly 0 in every unit
/// — the "reads 0 after taring" guarantee. It holds because net is a
/// DIFFERENCE of the board map between the reading and the tare point
/// (piecewise nonlinearity applies on both sides); subtracting the tare in
/// counts and mapping after would instead map zero counts to the board's
/// dead-short offset, which is not zero.
///
/// Raw and mV take only the offset: raw bypasses the board map entirely,
/// and mV rests on [ChannelBoardCalibration.displayExcitationV] — the one
/// conversion input the calibration never characterized.
class ChannelConverter {
  const ChannelConverter(this.calibration, this.tare);

  final ChannelCalibration calibration;

  /// Tare offset in counts; null = no offset. Zero counts is not a
  /// meaningful anchor (the board's physical zero is its dead-short
  /// reading), so "untared" is null, never 0.
  final double? tare;

  /// The board map and the unit's per-mV/V scale, or null when the unit is
  /// unavailable on the channel. The one place the two are resolved
  /// together; every converted path starts here and raw paths skip it.
  ({ChannelBoardCalibration board, double scale})? _boardAndScale(
    DisplayUnit unit,
  ) {
    final board = calibration.board;
    if (board == null) return null;
    final scale = _scalePerMvV(unit);
    return scale == null ? null : (board: board, scale: scale);
  }

  /// The multiplier applied to net mV/V for [unit]: force units fold in
  /// the cell's kgf-per-mV/V, mV folds in the excitation anchor, mV/V is
  /// unity. Null when the unit is unavailable on the channel: any converted
  /// unit with no board data, or a force unit with no load cell assigned.
  /// Raw never consults this.
  double? _scalePerMvV(DisplayUnit unit) {
    final board = calibration.board;
    if (board == null) return null;
    final excitationV = board.displayExcitationV;
    final f = unit.kgfFactor;
    if (f != null) {
      final cell = calibration.loadCell;
      return cell == null ? null : f * cell.kgfPerMvV;
    }
    return unit == DisplayUnit.mV ? excitationV : 1.0;
  }

  /// The absolute-raw -> display-unit map, net of tare (see the class doc).
  /// Monotone nondecreasing. A null tare means NO offset: the map itself
  /// (zero is the map's own mV/V zero point, not zero counts). Null when
  /// unavailable: a force unit on a channel with no assigned load cell, or
  /// any converted unit with no board data.
  double Function(double raw)? netMap(DisplayUnit unit) {
    if (unit == DisplayUnit.raw) return (raw) => raw - (tare ?? 0);
    final resolved = _boardAndScale(unit);
    if (resolved == null) return null;
    final board = resolved.board;
    // The tare-side map value is loop-invariant; the closure runs per
    // sample on the hot paths (graph reduction, stats).
    final tareMvV = tare == null ? 0.0 : board.mvVFromRaw(tare!);
    return (raw) => (board.mvVFromRaw(raw) - tareMvV) * resolved.scale;
  }

  /// The absolute-raw -> display-unit map with no tare netting: the GROSS
  /// value at a raw point. Used to show where a tare sits (the tare is
  /// stored in counts; its display value is the map evaluated there). Null
  /// exactly when [netMap] is.
  double Function(double raw)? grossMap(DisplayUnit unit) {
    if (unit == DisplayUnit.raw) return (raw) => raw;
    final resolved = _boardAndScale(unit);
    if (resolved == null) return null;
    return (raw) => resolved.board.mvVFromRaw(raw) * resolved.scale;
  }

  /// The raw-diff -> display-unit map (no tare: offsets cancel in a
  /// difference). Uses the channel's terminal slope so the map is
  /// position-free (the derivative graph's bucket fast path needs that); the
  /// local slope differs from the terminal chord only by the board's
  /// nonlinearity (ppm-level); the gain is a constant that cancels. Null
  /// exactly when [netMap] is.
  double Function(double rawDiff)? diffMap(DisplayUnit unit) {
    final perCount = countQuantum(unit);
    if (perCount == null) return null;
    return (diff) => diff * perCount;
  }

  /// The value of 1 ADC count in [unit]: the CSV export's fixed-point
  /// quantum (see `exportDecimalsFor` in csv_export.dart) and the
  /// derivative path's per-count scale (see [diffMap]). Raw bypasses the
  /// board map, so its quantum is exactly 1 count. Null exactly when
  /// [netMap] is.
  double? countQuantum(DisplayUnit unit) {
    if (unit == DisplayUnit.raw) return 1.0;
    final resolved = _boardAndScale(unit);
    if (resolved == null) return null;
    return resolved.scale / resolved.board.sensitivityCountsPerMvV;
  }

  /// One-shot [netMap] call.
  double? net(DisplayUnit unit, double raw) => netMap(unit)?.call(raw);

  /// One-shot [grossMap] call.
  double? gross(DisplayUnit unit, double raw) => grossMap(unit)?.call(raw);

  /// The display value of the tare point in [unit]: the amount the net
  /// converter subtracts, i.e. the gross value there. "No offset" is
  /// exactly 0 in every unit. Null when the unit is unavailable for the
  /// channel (and a tare is set).
  double? tareOffset(DisplayUnit unit) {
    final t = tare;
    if (t == null) return 0;
    return gross(unit, t);
  }

  /// Inverse of [grossMap]: the raw count at which the channel's gross map
  /// reads [value] in [unit]. Manual tare entry stores counts, so a typed
  /// display value converts back through here. Null exactly when [grossMap]
  /// is.
  double? rawAtGross(DisplayUnit unit, double value) {
    if (unit == DisplayUnit.raw) return value;
    final resolved = _boardAndScale(unit);
    if (resolved == null) return null;
    return resolved.board.rawFromMvV(value / resolved.scale);
  }
}
