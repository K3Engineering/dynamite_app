import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/app_settings.dart';
import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/screens/settings_tab.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/demo_device.dart';
import 'package:dynamite_app/services/mockble.dart';
import 'package:dynamite_app/services/rig_state.dart';

/// Widget tests for the Settings tab's device gating: with no link up, the
/// device-owned sections (load cell slots, board calibration) must not
/// render — their values are read from the connected hardware, so without
/// hardware they don't exist. The board-calibration row's connected state
/// uses the demo link (brought up directly — [BleLinkManager.connectToDemoDevice]
/// is synchronous); the remaining connected content is covered by its own
/// widget tests.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Install the mock regardless of useMockBt so BleLinkManager's
    // unawaited availability query resolves without platform channels (same
    // pattern as widget_test.dart).
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.dropEveryNPackets = 0;
  });

  Future<BleLinkManager> pump(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    final events = AppEvents();
    final link = BleLinkManager(events: events, demo: DemoDevice());
    final hub = DataHub();
    final rig = RigState(transport: link, prefs: prefs);
    // Wire the link's calibration read to the rig — the app's wiring goes
    // through the packet decoder; the test shortcuts the (separately
    // tested) parsing.
    link.onCalibrationData = (data, gains) {
      final flash = DeviceFlash.parse(utf8.decode(data), pgaGains: gains);
      hub.updateBoardCalibration(flash.board);
      rig.onFlashRead(link.connectedDeviceId, link.connectedDeviceName, flash);
      hub.updateLoadCells(rig.channelCells);
    };
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(
            value: AppSettings(prefs: prefs),
          ),
          ChangeNotifierProvider<DataHub>.value(value: hub),
          ChangeNotifierProvider<BleLinkManager>.value(value: link),
          ChangeNotifierProvider<RigState>.value(value: rig),
        ],
        child: MaterialApp(
          home: Scaffold(body: SettingsTab(onGoToDevices: () {})),
        ),
      ),
    );
    // Pump past the construction-time BLE timers (the mock's 200ms
    // availability query and universal_ble's 5s command-queue timeout) so
    // none are left pending at the end-of-test timer check — same pattern
    // as widget_test.dart.
    await tester.pump(const Duration(seconds: 6));
    return link;
  }

  testWidgets('no device connected: connect prompt, no device sections', (
    tester,
  ) async {
    await pump(tester);

    // App-owned settings still render (visible without scrolling).
    expect(find.text('Display Units'), findsOneWidget);
    expect(find.text('Load cells'), findsNothing);
    expect(find.text('Board calibration'), findsNothing);

    // The app-settings section is taller than the test viewport, so the
    // device section is below the fold: scroll it into view (the ListView
    // builds off-screen children lazily).
    await tester.dragUntilVisible(
      find.text('No device connected'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    expect(find.text('No device connected'), findsOneWidget);
  });

  testWidgets('no board constants: only Raw is selectable', (tester) async {
    await pump(tester);

    final groups = tester
        .widgetList<SegmentedButton<DisplayUnit>>(
          find.byType(SegmentedButton<DisplayUnit>),
        )
        .toList();
    expect(groups, hasLength(2));
    final electrical = groups[1];
    expect(electrical.selected, {DisplayUnit.raw});
    expect(
      electrical.segments
          .singleWhere((s) => s.value == DisplayUnit.mVv)
          .enabled,
      isFalse,
    );
    expect(
      electrical.segments
          .singleWhere((s) => s.value == DisplayUnit.raw)
          .enabled,
      isTrue,
    );
    expect(groups[0].segments.every((s) => s.enabled == false), isTrue);
  });

  testWidgets('connected: the board calibration row summarizes and opens', (
    tester,
  ) async {
    // A tall surface: the tab's ListView is lazy, and the row sits below
    // the fold at the default size.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final link = await pump(tester);
    await link.connectToDemoDevice();
    await tester.pump();

    // The row carries the demo document's calibration date.
    expect(find.text('Board calibration'), findsOneWidget);
    expect(find.textContaining('Calibrated 2026-07-20'), findsOneWidget);

    // The row opens the calibration page (the trust line only renders
    // there).
    await tester.tap(find.text('Board calibration'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('±0.5% of reading'), findsOneWidget);

    // Teardown: bring the demo link down so its feed timer stops, then
    // drain the command-queue timeout (see device_action_buttons_test).
    await link.disconnectSelectedDevice();
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('device name editor: save and clear round-trip', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final link = await pump(tester);
    await link.connectToDemoDevice();
    await tester.pump();

    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    // Unset on the demo: empty field, factory name displayed.
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(link.connectedDeviceName, 'Demo Device');

    // Save a name: the display name overlays everywhere.
    await tester.enterText(field, 'Rack 4 (West)');
    await tester.pump();
    await tester.tap(find.byKey(const Key('device_name_save')));
    await tester.pump();
    expect(link.connectedDeviceName, 'Rack 4 (West)');
    expect(link.connectedStoredDeviceName, 'Rack 4 (West)');

    // Clear: the field reverts to empty and the factory name returns.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.tap(find.byKey(const Key('device_name_save')));
    await tester.pump();
    expect(link.connectedDeviceName, 'Demo Device');
    expect(link.connectedStoredDeviceName, isNull);

    await link.disconnectSelectedDevice();
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('device name editor: invalid input blocks the save', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final link = await pump(tester);
    await link.connectToDemoDevice();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Bad,Name');
    await tester.pump();

    expect(
      find.textContaining('start with a letter or digit'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('device_name_save')))
          .onPressed,
      isNull,
    );
    expect(link.connectedStoredDeviceName, isNull);

    await link.disconnectSelectedDevice();
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
  });
}
