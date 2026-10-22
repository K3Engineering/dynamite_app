import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Pins the FIXED-SCALE decision for the graph canvas (documented on
/// `_kGraphLeftSpace`/`kGraphRightSpace` in graph_components.dart): axis
/// labels are painted at a literal 13 px into constant-size gutters and do
/// NOT follow `MediaQuery.textScaler`.
///
/// The point of these tests is not that scaling would be nice — it is that
/// the half-measure is a real bug class. `_drawAxis` clips labels to a strip
/// measured from the paragraphs, inside a gutter whose size was fixed before
/// layout, so scaling the text alone clips it at the canvas edge instead of
/// growing the plot's reserve. Anyone who adds a scaler must therefore grow
/// both gutters (making `kGraphRightSpace` state shared with the controls
/// row and minimap) and rewrite this file deliberately.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const large = TextScaler.linear(2);

  test('the axis-label cache carries no text scaler', () {
    // AxisLabelCache.prepare takes text/color/bold and nothing else: there is
    // no scaler input to forget to thread, which is why the paragraphs are
    // identical whatever MediaQuery says. Height comes from the fixed 13 px
    // style (with whatever line metrics the test font reports).
    final cache = AxisLabelCache();
    addTearDown(cache.dispose);

    final paragraph = cache.prepare('12345');
    expect(paragraph.height, greaterThan(0));
    // Sanity: the same key returns the same laid-out paragraph, so this test
    // is measuring the cache rather than a fresh build each time.
    expect(identical(cache.prepare('12345'), paragraph), isTrue);
  });

  test('the gutters stay at their fixed sizes', () {
    // Public because GraphViewControls aligns its right edge to it; if this
    // ever becomes dynamic, every reader (controls row, minimap, both
    // painters) has to move together.
    expect(kGraphRightSpace, 56);
  });

  testWidgets('the workspace renders at 2x text scale without asserting or '
      'clipping itself apart', (tester) async {
    // A large scale must not throw, overflow, or drop the graph: the canvas
    // simply keeps its instrument scale. Contrast with the widget-rendered
    // readouts around it, which do scale (that is why the trade-off is
    // acceptable).
    final handle = tester.ensureSemantics();

    final hub = DataHub();
    final frame = Int32List(kAdcChannelCount);
    for (int i = 0; i < 64; i++) {
      frame[0] = 1000 + i;
      hub.addSampleFrame(frame);
    }
    hub.commitBatch(0);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: large),
          child: GraphWorkspace(
            data: hub,
            ctrl: GraphController(),
            unit: DisplayUnit.mVv.effective(hub.unitAvailability),
            activeChannels: const [0, 1],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // Still a described graph, not a blank canvas.
    expect(
      find.bySemanticsLabel(
        'Live force graph. Channels: CH 0, CH 1. Unit: Raw.',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });
}
