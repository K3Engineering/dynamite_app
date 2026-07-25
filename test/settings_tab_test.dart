import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/app_settings.dart';
import 'package:dynamite_app/screens/settings_tab.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/mockble.dart';

/// Widget tests for the Settings tab's device gating: with no link up, the
/// device-owned sections (load cell slots, board calibration) must not
/// render — their values are read from the connected hardware, so without
/// hardware they don't exist. (The sections' connected-state content is
/// covered by their own widget tests.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    UniversalBle.setInstance(MockBlePlatform.instance);
    final events = AppEvents();
    final link = BleLinkManager(events: events);
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(
            value: AppSettings(prefs: prefs),
          ),
          ChangeNotifierProvider<BleLinkManager>.value(value: link),
        ],
        child: const MaterialApp(home: Scaffold(body: SettingsTab())),
      ),
    );
    // Pump past the construction-time BLE timers (the mock's 200ms
    // availability query and universal_ble's 5s command-queue timeout) so
    // none are left pending at the end-of-test timer check — same pattern
    // as widget_test.dart.
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets('no device connected: connect prompt, no device sections', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('No device connected'), findsOneWidget);
    expect(find.text('Load cells'), findsNothing);
    expect(find.text('Board calibration'), findsNothing);
    // App-owned settings still render.
    expect(find.text('Display Units'), findsOneWidget);
  });
}
