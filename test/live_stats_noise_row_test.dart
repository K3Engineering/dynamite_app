import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/screens/live_tab.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/models/feed_health.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Widget test for the debug-only "AC RMS" row in the live stats: hidden by
/// default, appearing (with the trailing-window sigma in display units) once
/// the setting is enabled.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('AC RMS row is gated by the debug-values setting', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = AppSettings(prefs: prefs);
    final hub = DataHub();
    // Alternating ±100 counts: sigma 100. Ends on -100, so only the Peak and
    // AC RMS rows can show '+100'.
    final frame = Int32List(kAdcChannelCount);
    for (int i = 0; i < 1000; i++) {
      frame.fillRange(0, kAdcChannelCount, i.isEven ? 100 : -100);
      hub.addSampleFrame(frame);
    }
    Future<void> pumpStats() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveStats(
            settings: settings,
            rig: RigState(
              backend: () => null,
              connectedDeviceName: () => 'Bench unit',
              prefs: prefs,
              events: AppEvents(),
            ),
            hub: hub,
            ctrl: GraphController(),
            unit: DisplayUnit.raw,
            healthListenable: ValueNotifier<FeedHealth?>(null),
          ),
        ),
      ),
    );
    await pumpStats();

    expect(find.text('AC RMS (4 s)'), findsNothing);
    expect(find.text('+100'), findsNWidgets(kAdcChannelCount)); // Peak only

    // AppSettings has no listener in this harness: re-pump so the row gate
    // re-reads the flag.
    await settings.setShowDebugLiveValues(true);
    await pumpStats();

    expect(find.text('AC RMS (4 s)'), findsOneWidget);
    expect(find.text('+100'), findsNWidgets(kAdcChannelCount * 2));
  });
}
