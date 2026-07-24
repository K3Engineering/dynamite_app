import 'calibration.dart';

/// Hardware AFE constants ([adcFullScaleV], [frontEndGain],
/// [adcCountsPerPolarity], [rawToMvMultiplier]) live in
/// models/calibration.dart — re-exported so existing importers keep working.
export 'calibration.dart'
    show adcFullScaleV, frontEndGain, adcCountsPerPolarity, rawToMvMultiplier;

/// Supported force and electrical display units.
///
/// Conversion is per channel: a unit maps absolute raw ADC counts to the
/// display value net of tare via the channel's [ChannelCalibration] (the
/// board's piecewise map plus the assigned load cell). Force units are
/// unavailable — a null converter — for channels without an assigned load
/// cell; the UI shows '—' there. Electrical units are always available.
enum ForceUnit {
  kN('kN', 'Kilonewtons', kgfFactor: 9.80665 / 1000),
  lbf('lbf', 'Pounds-force', kgfFactor: 2.20462),
  kgf('kgf', 'Kilogram-force', kgfFactor: 1.0),
  n('N', 'Newtons', kgfFactor: 9.80665),
  mVv('mV/V', 'Cell output ratio'),
  mV('mV', 'Cell output voltage'),
  raw('Raw', 'ADC Counts');

  const ForceUnit(this.symbol, this.label, {this.kgfFactor});

  final String symbol;
  final String label;

  /// 1 kgf expressed in this unit (force units only); null for electrical
  /// units, which convert through the board calibration alone.
  final double? kgfFactor;

  /// Force units need an assigned load cell; electrical units only need the
  /// board calibration. Drives the Settings picker's grouping.
  bool get isForce => kgfFactor != null;

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
    final board = channel.board;
    final tareMvV = board.mvVFromRaw(tare);
    final f = kgfFactor;
    if (f != null) {
      final cell = channel.loadCell;
      if (cell == null) return null;
      final scale = f * cell.kgfPerMvV;
      return (raw) => (board.mvVFromRaw(raw) - tareMvV) * scale;
    }
    return switch (this) {
      ForceUnit.mVv => (raw) => board.mvVFromRaw(raw) - tareMvV,
      ForceUnit.mV =>
        (raw) => (board.mvVFromRaw(raw) - tareMvV) * board.effectiveExcitationV,
      ForceUnit.raw => (raw) => raw - tare,
      _ => throw StateError('$this is a force unit'),
    };
  }

  /// Build the raw-diff -> display-unit converter for one channel (no tare:
  /// offsets cancel in a difference). Uses the channel's terminal slope:
  /// the piecewise-local slope differs by ppm, and the derivative graph's
  /// bucket fast path needs a position-free map. Null exactly when
  /// [converterFor] is.
  double Function(double rawDiff)? diffConverterFor(
    ChannelCalibration channel,
  ) {
    final span = channel.board.spanCountsPerMvV;
    final f = kgfFactor;
    if (f != null) {
      final cell = channel.loadCell;
      if (cell == null) return null;
      final scale = f * cell.kgfPerMvV / span;
      return (diff) => diff * scale;
    }
    return switch (this) {
      ForceUnit.mVv => (diff) => diff / span,
      ForceUnit.mV =>
        (diff) => diff / span * channel.board.effectiveExcitationV,
      ForceUnit.raw => (diff) => diff,
      _ => throw StateError('$this is a force unit'),
    };
  }

  /// Format a [value] (already in this unit) with an explicit sign, and a
  /// trailing [suffix] when given (e.g. the unit symbol).
  String _formatValue(double value, String suffix) {
    final sign = value < 0 ? '-' : '+';
    final decimals = switch (this) {
      ForceUnit.raw => 0,
      ForceUnit.mV || ForceUnit.mVv => 4,
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
