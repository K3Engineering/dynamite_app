// Selection state for the analysis pane slot in [GraphWorkspace]: which
// derived view (if any) sits between the force graph and the minimap, plus
// every pane's parameters. Pure data — the widgets live in
// `analysis_pane_bar.dart`, the painters in `graph_components.dart`.
//
// Owned by each screen in a ValueNotifier (ephemeral; not persisted).

/// What occupies the analysis pane slot. Null = the slot is collapsed.
enum AnalysisPaneKind { derivative }

/// Immutable pane selection + parameters. `copyWith` fields default to
/// "keep current" via the [_unset] sentinel so [kind] can be set back to
/// null explicitly.
final class AnalysisPaneSelection {
  const AnalysisPaneSelection({this.kind});

  final AnalysisPaneKind? kind;

  static const Object _unset = Object();

  AnalysisPaneSelection copyWith({Object? kind = _unset}) {
    return AnalysisPaneSelection(
      kind: identical(kind, _unset) ? this.kind : kind as AnalysisPaneKind?,
    );
  }
}
