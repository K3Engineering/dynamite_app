import 'package:material_ui/material_ui.dart';

import '../models/analysis_pane.dart';
import '../models/device_profile.dart';
import '../models/load_cell.dart';
import '../utils/fft.dart';
import 'channel_palette.dart';

// ---------------------------------------------------------------------------
// Analysis pane selector + per-pane parameter rows
//
// One row of single-select chips picks the derived view (tapping the active
// chip again collapses the slot); a second row edits that pane's
// parameters. Used by both the live tab and the session review screen, keep
// it stateless: the screen owns the [AnalysisPaneSelection].
// ---------------------------------------------------------------------------

class AnalysisPaneBar extends StatelessWidget {
  const AnalysisPaneBar({
    super.key,
    required this.selection,
    required this.onChanged,
  });

  final AnalysisPaneSelection selection;
  final ValueChanged<AnalysisPaneSelection> onChanged;

  static const _kinds = <(AnalysisPaneKind, String)>[
    (AnalysisPaneKind.derivative, 'dF/dt'),
    (AnalysisPaneKind.fft, 'FFT'),
    (AnalysisPaneKind.sum, 'Sum'),
    (AnalysisPaneKind.balance, 'Balance'),
    (AnalysisPaneKind.diff, 'Diff'),
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
      AnalysisPaneKind.sum => Wrap(
        spacing: 8,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: _channelChips(
          selected: sel.sumChannels,
          onToggle: (ch) => onChanged(
            sel.copyWith(sumChannels: _toggled(sel.sumChannels, ch)),
          ),
        ),
      ),
      AnalysisPaneKind.balance => Wrap(
        spacing: 8,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ChoiceChip(
            label: const Text('1D line'),
            selected: sel.balanceMode == BalanceMode.line,
            onSelected: (_) =>
                onChanged(sel.copyWith(balanceMode: BalanceMode.line)),
            visualDensity: VisualDensity.compact,
          ),
          ChoiceChip(
            label: const Text('2D plate'),
            selected: sel.balanceMode == BalanceMode.plate,
            onSelected: (_) =>
                onChanged(sel.copyWith(balanceMode: BalanceMode.plate)),
            visualDensity: VisualDensity.compact,
          ),
          const _ParamsDivider(),
          if (sel.balanceMode == BalanceMode.line)
            ..._pairDropdowns(
              a: sel.balanceLineA,
              b: sel.balanceLineB,
              onA: (v) => onChanged(sel.copyWith(balanceLineA: v)),
              onB: (v) => onChanged(sel.copyWith(balanceLineB: v)),
            )
          else
            _CornerGrid(
              corners: sel.balanceCorners,
              onTapCorner: (i) => onChanged(
                sel.copyWith(
                  balanceCorners: _cycledCorner(sel.balanceCorners, i),
                ),
              ),
            ),
        ],
      ),
      AnalysisPaneKind.diff => Row(
        mainAxisSize: MainAxisSize.min,
        children: _pairDropdowns(
          a: sel.diffA,
          b: sel.diffB,
          onA: (v) => onChanged(sel.copyWith(diffA: v)),
          onB: (v) => onChanged(sel.copyWith(diffB: v)),
        ),
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

  /// The two dropdowns of a channel pair, laid out so "B − A" reads
  /// left-to-right the way the pane plots it.
  List<Widget> _pairDropdowns({
    required int a,
    required int b,
    required ValueChanged<int> onA,
    required ValueChanged<int> onB,
  }) => [
    _channelDropdown(value: b, onChanged: onB),
    const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Text('−'),
    ),
    _channelDropdown(value: a, onChanged: onA),
  ];

  Widget _channelDropdown({
    required int value,
    required ValueChanged<int> onChanged,
  }) => DropdownButton<int>(
    value: value,
    isDense: true,
    items: [
      for (int ch = 0; ch < kAdcChannelCount; ch++)
        DropdownMenuItem(value: ch, child: Text(rigSlotTitle(ch))),
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
    for (int ch = 0; ch < kAdcChannelCount; ch++)
      FilterChip(
        avatar: CircleAvatar(backgroundColor: getChannelColor(ch), radius: 5),
        label: Text('CH $ch'),
        selected: selected.contains(ch),
        onSelected: (_) => onToggle(ch),
        visualDensity: VisualDensity.compact,
      ),
  ];

  /// Tap on a corner gives it the next channel value, swapping with the
  /// corner that held it — so the assignment stays a permutation.
  static List<int> _cycledCorner(List<int> corners, int index) {
    final next = List<int>.of(corners);
    final v = (next[index] + 1) % kAdcChannelCount;
    final holder = next.indexOf(v);
    next[holder] = next[index];
    next[index] = v;
    return next;
  }
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

/// The 2×2 corner assignment grid for the plate view. Each chip shows the
/// corner position and its channel; tapping cycles the channel (see
/// [AnalysisPaneBar._cycledCorner]).
class _CornerGrid extends StatelessWidget {
  const _CornerGrid({required this.corners, required this.onTapCorner});

  /// Per-corner hardware channel [TL, TR, BL, BR].
  final List<int> corners;
  final ValueChanged<int> onTapCorner;

  static const _cornerNames = ['TL', 'TR', 'BL', 'BR'];

  @override
  Widget build(BuildContext context) {
    const chipW = 86.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [(0, 1), (2, 3)])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final i in [row.$1, row.$2])
                SizedBox(
                  width: chipW,
                  child: ActionChip(
                    avatar: CircleAvatar(
                      backgroundColor: getChannelColor(corners[i]),
                      radius: 5,
                    ),
                    label: Text('${_cornerNames[i]} · CH ${corners[i]}'),
                    onPressed: () => onTapCorner(i),
                    visualDensity: VisualDensity.compact,
                    labelStyle: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
