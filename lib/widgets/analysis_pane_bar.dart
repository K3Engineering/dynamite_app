import 'package:material_ui/material_ui.dart';

import '../models/analysis_pane.dart';
import '../models/derived_channel.dart';
import '../utils/fft.dart';

// ---------------------------------------------------------------------------
// Analysis pane selector + per-pane parameter rows
//
// One row of single-select chips picks the derived view (tapping the active
// chip again collapses the slot); a second row edits that pane's
// parameters. Used by both the live tab and the session review screen, keep
// it stateless: the screen owns the [AnalysisPaneSelection].
//
// The panes take the workspace's channel selection (the stats-table
// toggles), so no pane picks channels here.
// ---------------------------------------------------------------------------

class AnalysisPaneBar extends StatelessWidget {
  const AnalysisPaneBar({
    super.key,
    required this.selection,
    required this.onChanged,
    required this.mathProfile,
  });

  final AnalysisPaneSelection selection;
  final ValueChanged<AnalysisPaneSelection> onChanged;

  /// The rig's configured math channels; the Plate chip only exists when
  /// the profile has plate semantics.
  final MathProfile mathProfile;

  @override
  Widget build(BuildContext context) {
    final sel = selection;
    final kinds = <(AnalysisPaneKind, String)>[
      (AnalysisPaneKind.derivative, 'dF/dt'),
      (AnalysisPaneKind.fft, 'FFT'),
      if (mathProfile.plateXId != null) (AnalysisPaneKind.plate, 'Plate'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final (kind, label) in kinds)
                FilterChip(
                  label: Text(label),
                  selected: sel.kind == kind,
                  onSelected: (on) =>
                      onChanged(sel.copyWith(kind: on ? kind : null)),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          if (sel.kind != null) ...[
            const SizedBox(height: 4),
            _paneParams(context),
          ],
        ],
      ),
    );
  }

  Widget _paneParams(BuildContext context) {
    final sel = selection;
    return switch (sel.kind) {
      null ||
      AnalysisPaneKind.derivative ||
      AnalysisPaneKind.plate => const SizedBox.shrink(),
      AnalysisPaneKind.fft => Wrap(
        spacing: 8,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ..._nChips,
          const _ParamsDivider(),
          ..._modeChips,
          const _ParamsDivider(),
          ..._xChips,
        ],
      ),
    };
  }

  List<Widget> get _nChips => [
    ChoiceChip(
      label: const Text('auto'),
      selected: selection.fftN == null,
      onSelected: (_) => onChanged(selection.copyWith(fftN: null)),
      visualDensity: VisualDensity.compact,
    ),
    for (final n in kFftNOptions)
      ChoiceChip(
        label: Text(n >= 1000 ? '${n ~/ 1024}k' : '$n'),
        selected: selection.fftN == n,
        onSelected: (_) => onChanged(selection.copyWith(fftN: n)),
        visualDensity: VisualDensity.compact,
      ),
  ];

  List<Widget> get _modeChips => [
    ChoiceChip(
      label: const Text('ampl'),
      selected: !selection.fftAsd,
      onSelected: (_) => onChanged(selection.copyWith(fftAsd: false)),
      visualDensity: VisualDensity.compact,
    ),
    ChoiceChip(
      label: const Text('/√Hz'),
      selected: selection.fftAsd,
      onSelected: (_) => onChanged(selection.copyWith(fftAsd: true)),
      visualDensity: VisualDensity.compact,
    ),
  ];

  List<Widget> get _xChips => [
    ChoiceChip(
      label: const Text('lin Hz'),
      selected: !selection.fftLogX,
      onSelected: (_) => onChanged(selection.copyWith(fftLogX: false)),
      visualDensity: VisualDensity.compact,
    ),
    ChoiceChip(
      label: const Text('log Hz'),
      selected: selection.fftLogX,
      onSelected: (_) => onChanged(selection.copyWith(fftLogX: true)),
      visualDensity: VisualDensity.compact,
    ),
  ];
}

/// Thin vertical separator between parameter groups.
class _ParamsDivider extends StatelessWidget {
  const _ParamsDivider();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 24,
    child: VerticalDivider(
      width: 9,
      thickness: 1,
      color: Theme.of(context).colorScheme.outlineVariant,
    ),
  );
}
