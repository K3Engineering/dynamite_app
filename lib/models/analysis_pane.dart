import 'cell_comparison.dart';
import 'device_profile.dart';

// Selection state for the analysis pane slot in [GraphWorkspace]: which
// derived view (if any) sits between the force graph and the minimap, plus
// every pane's parameters. Pure data — the widgets live in
// `analysis_pane_bar.dart`, the painters in `graph_components.dart`.
//
// Owned by each screen in a ValueNotifier (ephemeral; not persisted).

/// What occupies the analysis pane slot. Null = the slot is collapsed.
enum AnalysisPaneKind { derivative, fft, plate, compare }

/// Immutable pane selection + parameters. `copyWith` fields default to
/// "keep current" via the [_unset] sentinel so nullable fields ([kind],
/// [fftN]) can be set back to null explicitly.
final class AnalysisPaneSelection {
  const new({
    this.kind,
    this.fftN,
    this.fftAsd = false,
    this.fftLogX = false,
    this.comparisonA = 0,
    this.comparisonB = 1,
    this.comparisonMode = .total,
    this.comparisonFullScaleX = false,
  }) : assert(
         comparisonA >= 0 &&
             comparisonA < kAdcChannelCount &&
             comparisonB >= 0 &&
             comparisonB < kAdcChannelCount &&
             comparisonA != comparisonB,
         'comparison needs two distinct hardware channels',
       );

  final AnalysisPaneKind? kind;

  /// FFT length in samples; null = auto (largest pow2 that fits the window).
  final int? fftN;

  /// FFT Y-axis mode: true = amplitude spectral density (dBFS/√Hz, the
  /// N-invariant noise view), false = plain amplitude (dBFS, the tone view).
  final bool fftAsd;

  /// FFT X-axis scale: true = logarithmic (bin 1 .. Nyquist, DC has no log
  /// home and drops off the trace), false = linear (0 .. Nyquist).
  final bool fftLogX;

  /// Reference and compared hardware channels. Their calibrated forces are
  /// A and B respectively; the plot's raw coordinates are (A, B - A).
  final int comparisonA;
  final int comparisonB;

  /// Whether comparison shows total deviation or removes the fitted line.
  final ComparisonPlotMode comparisonMode;

  /// False fits X to the selected loads; true uses reference cell A's ±FS.
  final bool comparisonFullScaleX;

  static const Object _unset = Object();

  AnalysisPaneSelection copyWith({
    Object? kind = _unset,
    Object? fftN = _unset,
    bool? fftAsd,
    bool? fftLogX,
    int? comparisonA,
    int? comparisonB,
    ComparisonPlotMode? comparisonMode,
    bool? comparisonFullScaleX,
  }) {
    return AnalysisPaneSelection(
      kind: identical(kind, _unset) ? this.kind : kind as AnalysisPaneKind?,
      fftN: identical(fftN, _unset) ? this.fftN : fftN as int?,
      fftAsd: fftAsd ?? this.fftAsd,
      fftLogX: fftLogX ?? this.fftLogX,
      comparisonA: comparisonA ?? this.comparisonA,
      comparisonB: comparisonB ?? this.comparisonB,
      comparisonMode: comparisonMode ?? this.comparisonMode,
      comparisonFullScaleX: comparisonFullScaleX ?? this.comparisonFullScaleX,
    );
  }

  /// Select reference A. Choosing B's channel swaps the pair, keeping two
  /// distinct channels unrepresentable rather than showing a zero comparison.
  AnalysisPaneSelection withComparisonA(int channel) => copyWith(
    comparisonA: channel,
    comparisonB: channel == comparisonB ? comparisonA : comparisonB,
  );

  /// Select compared cell B; a collision swaps with A, like [withComparisonA].
  AnalysisPaneSelection withComparisonB(int channel) => copyWith(
    comparisonA: channel == comparisonA ? comparisonB : comparisonA,
    comparisonB: channel,
  );
}
