import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/app_settings.dart';
import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Paint smoke test for the limit chrome: with a cell assigned on one
/// channel, data inside its warning band, and another channel pinned at the
/// rail, the force pane paints the gutter ribbons and the rail display
/// (flood and dashes). No pixel assertions — the point is the paint path
/// executing end to end without throwing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channels = DataHub.numAdcChannels;

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
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettings(
      prefs: await SharedPreferences.getInstance(),
    );
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
    // Channel 0 sits at 90% of its rating (inside the default 80% warning
    // band, below the FSR limit); channel 1 is pinned at the positive rail.
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
          settings: settings,
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
