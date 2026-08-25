import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/graph_data_source.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Semantics-label tests for [GraphWorkspace]: the painted graph exposes a
/// container node describing what's plotted. The string is the entire guard
/// against the canvas being a screen-reader black hole, so its exact
/// composition (live/recorded, channel set, effective unit, derivative) is
/// pinned here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channels = kAdcChannelCount;

  const testNominals = ChannelNominals(
    adcFsrV: 1.2,
    afeGain: 101,
    pgaGain: 1,
    excitationV: 4.53,
  );

  DataHub calibratedHub() => DataHub()
    ..updateBoardCalibration(
      BoardCalibration(
        channels: [
          for (int i = 0; i < channels; i++)
            ChannelBoardCalibration(nominals: testNominals),
        ],
      ),
    );

  testWidgets('graph semantics label describes what is plotted', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    Future<void> pumpGraph({
      required GraphDataSource data,
      required List<int> activeChannels,
      bool isLiveGraph = true,
      bool showDerivative = false,
    }) => tester.pumpWidget(
      MaterialApp(
        home: GraphWorkspace(
          data: data,
          ctrl: GraphController(),
          unit: DisplayUnit.mVv,
          limitWarningsEnabled: true,
          activeChannels: activeChannels,
          isLiveGraph: isLiveGraph,
          showDerivative: showDerivative,
        ),
      ),
    );

    // Calibrated channels: mV/V converts, both channels are plotted.
    await pumpGraph(data: calibratedHub(), activeChannels: const [0, 1]);
    expect(
      find.bySemanticsLabel(
        'Live force graph. Channels: CH 1, CH 2. Unit: mV/V.',
      ),
      findsOneWidget,
    );

    // Recorded playback with the derivative pane on.
    await pumpGraph(
      data: calibratedHub(),
      activeChannels: const [0, 1],
      isLiveGraph: false,
      showDerivative: true,
    );
    expect(
      find.bySemanticsLabel(
        'Recorded force graph. Channels: CH 1, CH 2. Unit: mV/V. '
        'Rate-of-change graph below.',
      ),
      findsOneWidget,
    );

    // No board calibration: mV/V can't convert, so the effective unit is
    // Raw — the label reports the unit actually drawn.
    await pumpGraph(data: DataHub(), activeChannels: const [0, 1]);
    expect(
      find.bySemanticsLabel(
        'Live force graph. Channels: CH 1, CH 2. Unit: Raw.',
      ),
      findsOneWidget,
    );

    // No active channels.
    await pumpGraph(data: calibratedHub(), activeChannels: const []);
    expect(
      find.bySemanticsLabel(
        'Live force graph. No channels plotted. Unit: mV/V.',
      ),
      findsOneWidget,
    );

    // Unmount before the test ends: the live-follow ticker must be disposed
    // before the binding's no-pending-timers check.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    handle.dispose();
  });
}
