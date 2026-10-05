import 'package:material_ui/material_ui.dart';

import '../models/analysis_pane.dart';
import '../models/derived_channel.dart';
import '../models/graph_data_source.dart';
import 'analysis_pane_bar.dart';
import 'graph_components.dart';

/// The chrome row below a [GraphWorkspace]: the analysis-pane bar and the
/// zoom-window controls. Shared by the live tab and session replay.
class GraphViewControls extends StatelessWidget {
  const GraphViewControls({
    super.key,
    required this.selection,
    required this.onPaneChanged,
    required this.mathProfile,
    required this.data,
    required this.ctrl,
  });

  /// The analysis pane slot's selection, displayed by the pane bar.
  final AnalysisPaneSelection selection;
  final ValueChanged<AnalysisPaneSelection> onPaneChanged;

  /// Forwarded to [AnalysisPaneBar]: gates which pane chips exist.
  final MathProfile mathProfile;

  /// The plotted source and its viewport, driven by the zoom controls.
  final GraphDataSource data;
  final GraphController ctrl;

  @override
  Widget build(BuildContext context) {
    // The right inset matches the painters' Y-axis gutter so the zoom
    // cluster's right edge is collinear with the plot and minimap edges.
    // The left inset comes from [AnalysisPaneBar]'s own padding.
    return Padding(
      padding: const EdgeInsets.only(right: kGraphRightSpace),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: AnalysisPaneBar(
              selection: selection,
              onChanged: onPaneChanged,
              mathProfile: mathProfile,
            ),
          ),
          GraphZoomControls(data: data, ctrl: ctrl),
        ],
      ),
    );
  }
}
