// Selection state for the analysis pane slot in [GraphWorkspace]: which
// derived view (if any) sits between the force graph and the minimap, plus
// every pane's parameters. Pure data — the widgets live in
// `analysis_pane_bar.dart`, the painters in `graph_components.dart`.
//
// Owned by each screen in a ValueNotifier (ephemeral; not persisted).

/// What occupies the analysis pane slot. Null = the slot is collapsed.
enum AnalysisPaneKind { derivative, fft, sum, balance, diff }

/// The balance pane's two shapes: a two-cell position line, or the
/// four-corner plate view.
enum BalanceMode { line, plate }

/// Immutable pane selection + parameters. `copyWith` fields default to
/// "keep current" via the [_unset] sentinel so nullable fields ([kind],
/// [fftN]) can be set back to null explicitly.
final class AnalysisPaneSelection {
  const AnalysisPaneSelection({
    this.kind,
    this.fftChannels = const {0, 1, 2, 3},
    this.fftN,
    this.fftAsd = false,
    this.sumChannels = const {0, 1, 2, 3},
    this.balanceMode = BalanceMode.plate,
    this.balanceLineA = 0,
    this.balanceLineB = 1,
    this.balanceCorners = const [0, 1, 2, 3],
    this.diffA = 0,
    this.diffB = 1,
  });

  final AnalysisPaneKind? kind;

  /// Channels whose spectra the FFT pane overlays (empty = none selected).
  final Set<int> fftChannels;

  /// FFT length in samples; null = auto (largest pow2 that fits the window).
  final int? fftN;

  /// FFT Y-axis mode: true = amplitude spectral density (dBFS/√Hz, the
  /// N-invariant noise view), false = plain amplitude (dBFS, the tone view).
  final bool fftAsd;

  /// Channels added together by the Sum pane.
  final Set<int> sumChannels;

  final BalanceMode balanceMode;

  /// 1D balance endpoints: the pane plots (B − A)/(A + B).
  final int balanceLineA;
  final int balanceLineB;

  /// 2D balance corner → hardware channel assignment in plate order
  /// [top-left, top-right, bottom-left, bottom-right]. Kept a permutation
  /// of 0..3 by the corner-grid control.
  final List<int> balanceCorners;

  /// Diff pane pair: plots net([diffB]) − net([diffA]).
  final int diffA;
  final int diffB;

  static const Object _unset = Object();

  AnalysisPaneSelection copyWith({
    Object? kind = _unset,
    Set<int>? fftChannels,
    Object? fftN = _unset,
    bool? fftAsd,
    Set<int>? sumChannels,
    BalanceMode? balanceMode,
    int? balanceLineA,
    int? balanceLineB,
    List<int>? balanceCorners,
    int? diffA,
    int? diffB,
  }) {
    return AnalysisPaneSelection(
      kind: identical(kind, _unset) ? this.kind : kind as AnalysisPaneKind?,
      fftChannels: fftChannels ?? this.fftChannels,
      fftN: identical(fftN, _unset) ? this.fftN : fftN as int?,
      fftAsd: fftAsd ?? this.fftAsd,
      sumChannels: sumChannels ?? this.sumChannels,
      balanceMode: balanceMode ?? this.balanceMode,
      balanceLineA: balanceLineA ?? this.balanceLineA,
      balanceLineB: balanceLineB ?? this.balanceLineB,
      balanceCorners: balanceCorners ?? this.balanceCorners,
      diffA: diffA ?? this.diffA,
      diffB: diffB ?? this.diffB,
    );
  }
}
