import 'package:material_ui/material_ui.dart';

import '../models/graph_data_source.dart';
import 'graph_components.dart';

/// The chrome row below a [GraphWorkspace]: the dF/dt pane toggle and the
/// zoom-window controls. Shared by the live tab and session replay
class GraphViewControls extends StatelessWidget {
  const GraphViewControls({
    super.key,
    required this.showDerivative,
    required this.onToggleDerivative,
    required this.data,
    required this.ctrl,
  });

  /// Whether the derivative pane is shown.
  final bool showDerivative;
  final VoidCallback onToggleDerivative;

  /// The plotted source and its viewport, driven by the zoom controls.
  final GraphDataSource data;
  final GraphController ctrl;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          FilterChip(
            label: const Text('dF/dt'),
            selected: showDerivative,
            onSelected: (_) => onToggleDerivative(),
            visualDensity: VisualDensity.compact,
            labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: showDerivative ? cs.onSecondaryContainer : null,
            ),
          ),
          const Spacer(),
          GraphZoomControls(data: data, ctrl: ctrl),
        ],
      ),
    );
  }
}
