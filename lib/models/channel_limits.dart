import 'calibration.dart';

/// Severity of a channel's proximity to a measurement limit (ADC clip or
/// load cell full scale), evaluated by [ChannelLimits.levelForRaw].
enum LimitLevel {
  /// Comfortably inside every limit.
  ok,

  /// Past the configured caution fraction of a limit (see
  /// `AppSettings.lcWarnFraction`, default 80%): approaching the ceiling —
  /// mild warning.
  caution,

  /// At or past a limit: the ADC railed (data invalid) or the load cell's
  /// rated full scale was exceeded (mechanical overload).
  exceeded,
}

/// A channel's measurement limits: the ADC clip point (always) plus the
/// assigned load cell's rated full scale (when a cell is assigned).
///
/// Everything here is ABSOLUTE and raw-domain by design:
///   * Clipping is a property of the 24-bit converter: +/-2^23 counts,
///     regardless of tare, display unit, or front-end gain.
///   * Load cell full scale is a property of the cell's absolute output:
///     the rated mV/V applies to `mvVFromRaw(raw)`, NOT the tared net value
///     — taring under preload reduces the remaining headroom, and the
///     warnings must follow the physical load, not the displayed zero.
///
/// Both limits are always evaluated and the worst wins: on the pro (a
/// ~2.62 mV/V ceiling at nominal excitation) a 3 mV/V cell rails the ADC
/// before reaching its own rating, so the clip stays live even with a cell
/// assigned.
///
/// Raw anchors for the mV/V thresholds come from the board map's inverse
/// ([ChannelBoardCalibration.rawFromMvV]): factory-calibrated channels get
/// exact anchors, nominal channels the nominal chain. Tare never appears
/// here — it only shifts the DISPLAYED position of these absolute anchors
/// (the graph converts them through the channel's tared converter).
class ChannelLimits {
  ChannelLimits({required this.board, this.loadCellFsMvV});

  /// The channel's board calibration: the absolute raw <-> mV/V map.
  final ChannelBoardCalibration board;

  /// Rated full-scale output of the assigned load cell (mV/V of excitation,
  /// applied symmetrically to both polarities); null when no cell is
  /// assigned — the clip point is then the only limit.
  final double? loadCellFsMvV;

  /// Raw counts of the positive ADC rail (0x7FFFFF): a sample AT or above
  /// this is clipped.
  static const int clipRawPos = adcCountsPerPolarity - 1;

  /// Raw counts of the negative ADC rail (-0x800000): a sample AT or below
  /// this is clipped.
  static const int clipRawNeg = -adcCountsPerPolarity;

  /// Raw anchors of +/- load cell full scale (absolute mV/V inverted through
  /// the board map); null when no cell is assigned.
  late final double? lcFsRawPos = switch (loadCellFsMvV) {
    final fs? => board.rawFromMvV(fs),
    null => null,
  };
  late final double? lcFsRawNeg = switch (loadCellFsMvV) {
    final fs? => board.rawFromMvV(-fs),
    null => null,
  };

  /// Whether recorded extremes show an ADC rail hit (clipped data) on either
  /// polarity. [rawMax]/[rawMin] are a stream's absolute extremes, so this
  /// latches until the stream resets.
  static bool extremesClipped(int rawMax, int rawMin) =>
      rawMax >= clipRawPos || rawMin <= clipRawNeg;

  /// The worst proximity of [raw] to any active limit. [cautionFraction] is
  /// the fraction of full scale where the mild warning starts (0..1; see
  /// `AppSettings.lcWarnFraction`).
  LimitLevel levelForRaw(int raw, double cautionFraction) {
    var level = LimitLevel.ok;

    // ADC clip, always active: exceeded at the rails, caution from
    // cautionFraction of the half-scale.
    if (raw >= clipRawPos || raw <= clipRawNeg) return LimitLevel.exceeded;
    if (raw.abs() >= cautionFraction * adcCountsPerPolarity) {
      level = LimitLevel.caution;
    }

    // Load cell full scale: absolute output vs the rating, both polarities.
    final fsPos = lcFsRawPos;
    final fsNeg = lcFsRawNeg;
    if (fsPos != null && fsNeg != null) {
      if (raw >= fsPos || raw <= fsNeg) return LimitLevel.exceeded;
      final fs = loadCellFsMvV!;
      final cPos = board.rawFromMvV(cautionFraction * fs);
      final cNeg = board.rawFromMvV(-cautionFraction * fs);
      if (raw >= cPos || raw <= cNeg) return LimitLevel.caution;
    }
    return level;
  }
}
