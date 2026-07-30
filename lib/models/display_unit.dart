import 'dart:math' as math;

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
enum DisplayUnit {
  kN('kN', 'Kilonewtons', kgfFactor: 9.80665 / 1000),
  lbf('lbf', 'Pounds-force', kgfFactor: 2.20462),
  kgf('kgf', 'Kilogram-force', kgfFactor: 1.0),
  n('N', 'Newtons', kgfFactor: 9.80665),
  mVv('mV/V', 'Cell output ratio'),
  mV('mV', 'Cell output voltage'),
  raw('Raw', 'ADC Counts');

  const DisplayUnit(this.symbol, this.label, {this.kgfFactor});

  final String symbol;
  final String label;

  /// 1 kgf expressed in this unit (force units only); null for electrical
  /// units, which convert through the board calibration alone.
  final double? kgfFactor;

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

  /// The unit's verbatim symbol in a dynamite-csv file (docs/csv-format-v1.md):
  /// exactly as the firmware certificates write it — lowercase `raw`, `mV/V`
  /// with the slash — used in header suffixes and the metadata's
  /// `converted_unit`. Differs from [symbol] only for [DisplayUnit.raw]
  /// (whose display label is capitalized).
  String get csvSymbol => this == DisplayUnit.raw ? 'raw' : symbol;

  /// The value of 1 ADC count in this unit on [channel]: the export's
  /// fixed-point quantum (see [exportDecimalsFor]) and the derivative path's
  /// per-count scale (see [diffConverterFor]). Raw bypasses the board map,
  /// so its quantum is exactly 1 count. Null exactly when [converterFor] is
  /// (a force unit with no load cell assigned).
  double? countQuantumFor(ChannelCalibration channel) {
    if (this == DisplayUnit.raw) return 1.0;
    final scale = _scalePerMvV(channel);
    return scale == null ? null : scale / channel.board.spanCountsPerMvV;
  }

  /// Fixed-point decimals for this unit on [channel] in a dynamite-csv file
  /// (docs/csv-format-v1.md): one guard digit beyond the value of 1 ADC
  /// count in this unit (`ceil(1 − log10(quantum))`, clamped to 0..10),
  /// computed from the recorded board cal's span. Null exactly when
  /// [converterFor] is (a force unit with no load cell — the file column is
  /// all-blank, so no precision is needed).
  int? exportDecimalsFor(ChannelCalibration channel) {
    final quantum = countQuantumFor(channel)?.abs();
    if (quantum == null) return null;
    // The nudge keeps an exact power-of-ten quantum from gaining a spurious
    // extra decimal to floating-point error in the log.
    return (1 - math.log(quantum) / math.ln10 - 1e-9)
        .ceil()
        .clamp(0, 10)
        .toInt();
  }

  /// Force units need an assigned load cell; electrical units only need the
  /// board calibration. Drives the Settings picker's grouping.
  bool get isForce => kgfFactor != null;

  /// The multiplier applied to net mV/V for this unit on [channel]: force
  /// units fold in the cell's kgf-per-mV/V, mV folds in the board's
  /// effective excitation, mV/V is unity. Null when the unit is unavailable
  /// on the channel (a force unit with no load cell assigned). Raw counts
  /// bypass the board map entirely and never consult this.
  double? _scalePerMvV(ChannelCalibration channel) {
    final f = kgfFactor;
    if (f != null) {
      final cell = channel.loadCell;
      return cell == null ? null : f * cell.kgfPerMvV;
    }
    return this == DisplayUnit.mV ? channel.board.effectiveExcitationV : 1.0;
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
