import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/app_meta.dart';
import 'package:dynamite_app/models/bt_scan.dart';
import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/screens/settings_tab.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/demo_device.dart';
import 'package:dynamite_app/services/firmware_catalog.dart';
import 'package:dynamite_app/services/firmware_update_service.dart';
import 'helpers/mockble.dart';
import 'package:dynamite_app/services/rig_state.dart';

import 'helpers/flash_docs.dart';

/// Widget tests for the Settings tab's device gating. Device-owned sections
/// (load cell slots, board calibration) render only for a streaming link —
/// their values are read from the connected hardware, so without a ready
/// device they don't exist. Idle shows the connect prompt; the states
/// between (connecting, setting up, disconnecting) show a transition
/// placeholder. The board-calibration row's connected state uses the demo
/// link (brought up directly — [BleLinkManager.connectToDemoDevice] is
/// synchronous); the remaining connected content is covered by its own
/// widget tests.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Install the mock so BleLinkManager's unawaited availability query
    // resolves without platform channels (same pattern as widget_test.dart).
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.dropEveryNPackets = 0;
  });

  Future<BleLinkManager> pump(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    final events = AppEvents();
    final hub = DataHub();
    late final BleLinkManager link;
    final rig = RigState(
      backend: () => link.backend,
      connectedDeviceName: () => link.connectedDeviceName,
      prefs: prefs,
      events: events,
    );
    // Wire the link's flash read to the hub and rig, as main() does.
    link = BleLinkManager(
      events: events,
      demo: DemoDevice(),
      onAdcData: (_) {},
      onSampleRate: (_) {},
      onDeviceFlash: (flash) {
        hub.updateBoardCalibration(flash.board);
        rig.onFlashRead(
          link.connectedDeviceId,
          link.connectedDeviceName,
          flash,
        );
        hub.updateLoadCells(rig.channelCells);
      },
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(
            value: AppSettings(prefs: prefs),
          ),
          Provider<AppMeta>.value(
            value: const AppMeta(version: '0.0.0', buildNumber: '0'),
          ),
          ChangeNotifierProvider<DataHub>.value(value: hub),
          ChangeNotifierProvider<BleLinkManager>.value(value: link),
          ChangeNotifierProvider<RigState>.value(value: rig),
          // The firmware card reads this; the harness's demo link is
          // simulated, so the service never reaches the real catalog.
          ChangeNotifierProvider<FirmwareUpdateService>.value(
            value: FirmwareUpdateService(
              prefs: prefs,
              link: link,
              events: events,
              catalog: GithubReleaseCatalog(),
            ),
          ),
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

  testWidgets('connecting: transition placeholder, not the device sections', (
    tester,
  ) async {
    // A tall surface so the device section is on screen without scrolling.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final link = await pump(tester);

    // A GATT connect in flight: the link is `connecting`, its device-owned
    // facts are not readable, so the settings UI must show the transition
    // placeholder — not "No device connected" and not the device sections
    // mounted against placeholder data (the misleading calibration-failure
    // line and the "no slot data" card).
    unawaited(link.connectToDevice('2'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(link.linkState, BtLinkState.connecting);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('No device connected'), findsNothing);
    expect(find.text('Board calibration'), findsNothing);
    expect(find.text('Load cells'), findsNothing);
    expect(find.text('Could not read calibration data'), findsNothing);
    expect(find.byType(TextField), findsNothing);

    // Teardown: cancel the in-flight attempt, then drain the mock's
    // connect and command-queue timers.
    unawaited(link.disconnectSelectedDevice());
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(link.linkState, BtLinkState.idle);
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

  testWidgets('invalid flash streams raw; the board row says unreadable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    MockBlePlatform.instance.seedKvs(
      kvsFromDoc('adc_fsr=1.2\nexc=soon\nafe_gain=101'),
    );
    final link = await pump(tester);
    unawaited(link.connectToDevice('2'));
    await tester.pump(const Duration(seconds: 4));

    // A board the app can't fully make sense of still connects: it streams
    // raw counts and the calibration row says the data is unreadable.
    expect(link.isStreaming, isTrue);
    expect(link.linkState, BtLinkState.streaming);
    expect(find.text('Board calibration'), findsOneWidget);
    expect(
      find.textContaining('Calibration data unreadable — contact support'),
      findsOneWidget,
    );
    // A document is held, so the row opens the page, which names the reason.
    final row = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Board calibration'),
    );
    expect(row.onTap, isNotNull);
    await tester.tap(find.widgetWithText(ListTile, 'Board calibration'));
    await tester.pumpAndSettle();
    expect(find.textContaining('board constants: bad exc'), findsOneWidget);

    // Teardown: a GATT link's disconnect awaits the mock's platform timers, so
    // drive it with pumps rather than awaiting it inside the test body.
    unawaited(link.disconnectSelectedDevice());
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(link.linkState, BtLinkState.idle);
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

    expect(find.textContaining('start with a letter or digit'), findsOneWidget);
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
