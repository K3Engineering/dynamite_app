import 'device_profile.dart';

// Selection state for the analysis pane slot in [GraphWorkspace]: which
// derived view (if any) sits between the force graph and the minimap, plus
// every pane's parameters. Pure data — the widgets live in
// `analysis_pane_bar.dart`, the painters in `graph_components.dart`.
//
// Owned by each screen in a ValueNotifier (ephemeral; not persisted).

/// What occupies the analysis pane slot. Null = the slot is collapsed.
enum AnalysisPaneKind { derivative, fft, plate, readout }

/// Immutable pane selection + parameters. `copyWith` fields default to
/// "keep current" via the [_unset] sentinel so nullable fields ([kind],
/// [fftN]) can be set back to null explicitly.
final class AnalysisPaneSelection {
  const AnalysisPaneSelection({
    this.kind,
    this.fftChannels = const {0, 1, 2, 3},
    this.fftN,
    this.fftAsd = false,
    this.plateX = kAdcChannelCount + 1,
    this.plateY = kAdcChannelCount + 2,
    this.readoutChannel = kAdcChannelCount + 3,
  });

  final AnalysisPaneKind? kind;

  /// Channels whose spectra the FFT pane overlays, in the widened id space
  /// (hardware 0..3, derived 4..; empty = none selected).
  final Set<int> fftChannels;

  /// FFT length in samples; null = auto (largest pow2 that fits the window).
  final int? fftN;

  /// FFT Y-axis mode: true = amplitude spectral density (dBFS/√Hz, the
  /// N-invariant noise view), false = plain amplitude (dBFS, the tone view).
  final bool fftAsd;

  /// The 2D plate's axes: channel ids for the horizontal/vertical plate
  /// coordinates (the rig's normalized pair; defaults target the force
  /// plate preset's X/Y).
  final int plateX;
  final int plateY;

  /// Channel id the readout pane aggregates (RMS over the window).
  final int readoutChannel;

  static const Object _unset = Object();

  AnalysisPaneSelection copyWith({
    Object? kind = _unset,
    Set<int>? fftChannels,
    Object? fftN = _unset,
    bool? fftAsd,
    int? plateX,
    int? plateY,
    int? readoutChannel,
  }) {
    return AnalysisPaneSelection(
      kind: identical(kind, _unset) ? this.kind : kind as AnalysisPaneKind?,
      fftChannels: fftChannels ?? this.fftChannels,
      fftN: identical(fftN, _unset) ? this.fftN : fftN as int?,
      fftAsd: fftAsd ?? this.fftAsd,
      plateX: plateX ?? this.plateX,
      plateY: plateY ?? this.plateY,
      readoutChannel: readoutChannel ?? this.readoutChannel,
    );
  }
}
