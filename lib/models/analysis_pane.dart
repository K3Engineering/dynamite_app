// Selection state for the analysis pane slot in [GraphWorkspace]: which
// derived view (if any) sits between the force graph and the minimap, plus
// every pane's parameters. Pure data — the widgets live in
// `analysis_pane_bar.dart`, the painters in `graph_components.dart`.
//
// Owned by each screen in a ValueNotifier (ephemeral; not persisted).

/// What occupies the analysis pane slot. Null = the slot is collapsed.
enum AnalysisPaneKind { derivative, fft, plate, rms }

/// Immutable pane selection + parameters. `copyWith` fields default to
/// "keep current" via the [_unset] sentinel so nullable fields ([kind],
/// [fftN]) can be set back to null explicitly.
final class AnalysisPaneSelection {
  const AnalysisPaneSelection({
    this.kind,
    this.fftN,
    this.fftAsd = false,
    this.rmsChannel,
  });

  final AnalysisPaneKind? kind;

  /// FFT length in samples; null = auto (largest pow2 that fits the window).
  final int? fftN;

  /// FFT Y-axis mode: true = amplitude spectral density (dBFS/√Hz, the
  /// N-invariant noise view), false = plain amplitude (dBFS, the tone view).
  final bool fftAsd;

  /// Channel id the RMS pane aggregates (over the window); null = not yet
  /// chosen, the pane asks for a pick. (The FFT and dF/dt panes take the
  /// workspace's channel selection instead of a per-pane one.)
  final int? rmsChannel;

  static const Object _unset = Object();

  AnalysisPaneSelection copyWith({
    Object? kind = _unset,
    Object? fftN = _unset,
    bool? fftAsd,
    Object? rmsChannel = _unset,
  }) {
    return AnalysisPaneSelection(
      kind: identical(kind, _unset) ? this.kind : kind as AnalysisPaneKind?,
      fftN: identical(fftN, _unset) ? this.fftN : fftN as int?,
      fftAsd: fftAsd ?? this.fftAsd,
      rmsChannel: identical(rmsChannel, _unset)
          ? this.rmsChannel
          : rmsChannel as int?,
    );
  }
}
