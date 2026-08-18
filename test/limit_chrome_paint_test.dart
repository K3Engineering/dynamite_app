import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Paint smoke test for the limit chrome: with a channel pinned at the ADC
/// rail, the force pane paints the rail display (light + clip fills). No
/// pixel assertions — the point is the paint path executing end to end
/// without throwing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channels = kAdcChannelCount;

  /// Pro-like nominal chain (same fixture as channel_limits_test).
  const testNominals = ChannelNominals(
    adcFsrV: 1.2,
    afeGain: 101,
    pgaGain: 1,
    excitationV: 4.53,
  );

  testWidgets('limit chrome paints with data in the band and at the rail', (
    tester,
  ) async {
    final hub = DataHub();
    hub.updateBoardCalibration(
      BoardCalibration(
        channels: [
          for (int i = 0; i < channels; i++)
            ChannelBoardCalibration(nominals: testNominals),
        ],
      ),
    );
    hub.updateLoadCells([
      LoadCellProfile(capacityKg: 50, sensitivityMvV: 2.0),
      for (int i = 1; i < channels; i++) null,
    ]);

    final frame = Int32List(channels);
    // Channel 0 carries mid-scale data; channel 1 is pinned at the positive
    // rail.
    frame[0] = (0.9 * 2.0 * testNominals.countsPerMvV).round();
    frame[1] = 0x7FFFFF;
    for (var i = 0; i < 200; i++) {
      hub.addSampleFrame(frame);
    }

    final ctrl = GraphController();
    await tester.pumpWidget(
      MaterialApp(
        home: GraphWorkspace(
          data: hub,
          ctrl: ctrl,
          unit: DisplayUnit.mVv,
          limitWarningsEnabled: true,
          activeChannels: [for (int i = 0; i < channels; i++) i],
        ),
      ),
    );
    // A few frames: the rolling segment bakes complete.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);

    // Unmount before the test ends: the live-follow ticker must be disposed
    // before the binding's no-pending-timers check.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
