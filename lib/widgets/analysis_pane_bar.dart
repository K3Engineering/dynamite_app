import 'package:material_ui/material_ui.dart';

import '../models/analysis_pane.dart';

// ---------------------------------------------------------------------------
// Analysis pane selector
//
// One row of single-select chips picks the derived view (tapping the active
// chip again collapses the slot). Used by both the live tab and the session
// review screen, keep it stateless: the screen owns the
// [AnalysisPaneSelection].
// ---------------------------------------------------------------------------

class AnalysisPaneBar extends StatelessWidget {
  const AnalysisPaneBar({
    super.key,
    required this.selection,
    required this.onChanged,
  });

  final AnalysisPaneSelection selection;
  final ValueChanged<AnalysisPaneSelection> onChanged;

  @override
  Widget build(BuildContext context) {
    final sel = selection;
    const kinds = <(AnalysisPaneKind, String)>[
      (AnalysisPaneKind.derivative, 'dF/dt'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
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
    );
  }
}
