import 'package:material_ui/material_ui.dart';

import '../models/analysis_pane.dart';
import '../utils/fft.dart';
import 'channel_palette.dart';

// ---------------------------------------------------------------------------
// Analysis pane selector + per-pane parameter rows
//
// One row of single-select chips picks the derived view (tapping the active
// chip again collapses the slot); a second row edits that pane's
// parameters. Used by both the live tab and the session review screen, keep
// it stateless: the screen owns the [AnalysisPaneSelection].
//
// Channel ids span the widened space (hardware 0..3, derived 4.. — see
// `derived_channel.dart`); [channelLabels]/[channelUnitless] describe them.
// ---------------------------------------------------------------------------

class AnalysisPaneBar extends StatelessWidget {
  const AnalysisPaneBar({
    super.key,
    required this.selection,
    required this.onChanged,
    required this.channelLabels,
    required this.channelUnitless,
  });

  final AnalysisPaneSelection selection;
  final ValueChanged<AnalysisPaneSelection> onChanged;

  /// Display label per channel id (both lists index-aligned with the ids).
  final List<String> channelLabels;

  /// Whether each channel id is unitless (a normalized blend).
  final List<bool> channelUnitless;

  static const _kinds = <(AnalysisPaneKind, String)>[
    (AnalysisPaneKind.derivative, 'dF/dt'),
    (AnalysisPaneKind.fft, 'FFT'),
    (AnalysisPaneKind.plate, 'Plate'),
    (AnalysisPaneKind.readout, 'Readout'),
  ];

  @override
  Widget build(BuildContext context) {
    final sel = selection;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final (kind, label) in _kinds)
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
      null || AnalysisPaneKind.derivative => const SizedBox.shrink(),
      AnalysisPaneKind.fft => Wrap(
        spacing: 8,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ..._channelChips(
            selected: sel.fftChannels,
            onToggle: (ch) => onChanged(
              sel.copyWith(fftChannels: _toggled(sel.fftChannels, ch)),
            ),
          ),
          const _ParamsDivider(),
          ..._nChips,
          const _ParamsDivider(),
          ..._modeChips,
        ],
      ),
      AnalysisPaneKind.plate => Wrap(
        spacing: 8,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('x:'),
          _channelDropdown(
            value: sel.plateX,
            ids: _unitlessIds,
            onChanged: (v) => onChanged(sel.copyWith(plateX: v)),
          ),
          const Text('y:'),
          _channelDropdown(
            value: sel.plateY,
            ids: _unitlessIds,
            onChanged: (v) => onChanged(sel.copyWith(plateY: v)),
          ),
        ],
      ),
      AnalysisPaneKind.readout => _channelDropdown(
        value: sel.readoutChannel,
        ids: [for (int i = 0; i < channelLabels.length; i++) i],
        onChanged: (v) => onChanged(sel.copyWith(readoutChannel: v)),
      ),
    };
  }

  /// Ids of the unitless (normalized) channels, for the plate axes.
  List<int> get _unitlessIds => [
    for (int i = 0; i < channelLabels.length; i++)
      if (channelUnitless[i]) i,
  ];

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

  Widget _channelDropdown({
    required int value,
    required List<int> ids,
    required ValueChanged<int> onChanged,
  }) => DropdownButton<int>(
    value: ids.contains(value) ? value : null,
    isDense: true,
    hint: const Text('—'),
    items: [
      for (final id in ids)
        DropdownMenuItem(
          value: id,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(backgroundColor: getChannelColor(id), radius: 5),
              const SizedBox(width: 6),
              Text(channelLabels[id]),
            ],
          ),
        ),
    ],
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
  );

  static Set<int> _toggled(Set<int> channels, int ch) {
    final next = Set<int>.of(channels);
    if (!next.remove(ch)) next.add(ch);
    return next;
  }

  /// Channel toggle chips colored like their traces.
  List<Widget> _channelChips({
    required Set<int> selected,
    required ValueChanged<int> onToggle,
  }) => [
    for (int ch = 0; ch < channelLabels.length; ch++)
      FilterChip(
        avatar: CircleAvatar(backgroundColor: getChannelColor(ch), radius: 5),
        label: Text(channelLabels[ch]),
        selected: selected.contains(ch),
        onSelected: (_) => onToggle(ch),
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
