import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Pins the fixed-scale graph canvas (see `_kGraphLeftSpace`): labels do not
/// follow `MediaQuery.textScaler`. Scaling the text without also growing the
/// measured gutters clips labels, so adding a scaler means rewriting this file
/// together with the gutter layout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const large = TextScaler.linear(2);

  test('the axis-label cache carries no text scaler', () {
    // prepare takes no scaler, so the paragraphs are identical whatever
    // MediaQuery says.
    final cache = AxisLabelCache();
    addTearDown(cache.dispose);

    final paragraph = cache.prepare('12345');
    expect(paragraph.height, greaterThan(0));
    // Same key, same laid-out paragraph: this is measuring the cache.
    expect(identical(cache.prepare('12345'), paragraph), isTrue);
  });

  test('the gutters stay at their fixed sizes', () {
    // Every reader (both painters, the controls row, the minimap) sizes
    // against this; making it dynamic moves them together.
    expect(kGraphRightSpace, 56);
  });

  testWidgets('the workspace renders at 2x text scale without asserting or '
      'dropping the graph', (tester) async {
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
    // Still a described graph rather than a blank canvas.
    expect(
      find.bySemanticsLabel(
        'Live force graph. Channels: CH 0, CH 1. Unit: Raw.',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });
}
