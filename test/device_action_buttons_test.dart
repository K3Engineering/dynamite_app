import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/main.dart';
import 'package:dynamite_app/models/app_meta.dart';
import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/screens/devices_tab.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/demo_device.dart';
import 'package:dynamite_app/services/feed_health_tracker.dart';
import 'package:dynamite_app/services/mockble.dart';
import 'package:dynamite_app/services/recording_controller.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/services/session_metadata.dart';
import 'package:dynamite_app/services/stream_reset_coordinator.dart';

/// Layout contract for the Devices tab's action buttons: Scan/Stop (status
/// row), Connect (inactive rows) and Cancel/Disconnect (active row) all share
/// [deviceActionButtonWidth] and one right-edge column. The active row is a
/// plain surface with a slate link-state badge; its outlined Disconnect takes
/// the brown action accent, never the state color.
///
/// Driven through the real app shell with the mock BLE platform installed
/// (same harness as widget_test.dart). The demo device provides the active
/// row: its link comes up synchronously, so no scan timing is involved.
/// Finders are scoped to the Devices tab subtree — every tab is mounted at
/// once (IndexedStack) and the Settings tab has its own 'Connect' button.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.dropEveryNPackets = 0;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    final appEvents = AppEvents();
    final dataHub = DataHub();
    final decoder = AdcPacketDecoder(dataHub);
    final prefs = await SharedPreferences.getInstance();
    late final BleLinkManager linkManager;
    final rigState = RigState(
      backend: () => linkManager.backend,
      connectedDeviceName: () => linkManager.connectedDeviceName,
      prefs: prefs,
    );
    linkManager = BleLinkManager(
      events: appEvents,
      demo: DemoDevice(),
      onDeviceFlash: (flash) {
        dataHub.updateBoardCalibration(flash.board);
        rigState.onFlashRead(
          linkManager.connectedDeviceId,
          linkManager.connectedDeviceName,
          flash,
        );
      },
      onAdcData: decoder.onDataPacket,
      onSampleRate: (_) {},
    );
    StreamResetCoordinator(
      hub: dataHub,
      streamingChanges: linkManager,
      streamingNow: () => linkManager.isStreaming,
    );
    final recording = RecordingController(
      dataHub: dataHub,
      streamingChanges: linkManager,
      streamingNow: () => linkManager.isStreaming,
      deviceMetadataSnapshot: () => toSessionDeviceMetadata(
        name: linkManager.connectedDeviceName,
        info: linkManager.connectedDeviceInfo!,
      ),
      deviceKvsSnapshot: () => rigState.kvsSnapshot,
      onSessionBoundary: decoder.resetContinuity,
      events: appEvents,
    );
    final feedHealth = FeedHealthTracker(
      hub: dataHub,
      streamingChanges: linkManager,
      streamingNow: () => linkManager.isStreaming,
    );
    addTearDown(feedHealth.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: AppSettings(prefs: prefs)),
          Provider<AppMeta>.value(
            value: const AppMeta(version: '0.0.0', buildNumber: '0'),
          ),
          Provider.value(value: appEvents),
          Provider.value(value: feedHealth),
          ChangeNotifierProvider.value(value: dataHub),
          ChangeNotifierProvider.value(value: linkManager),
          ChangeNotifierProvider.value(value: rigState),
          ChangeNotifierProvider.value(value: recording),
        ],
        child: const DynoApp(),
      ),
    );
    // See widget_test.dart: settle the mock's startup round-trips AND the 5s
    // universal_ble command-queue timeout so no timer is left pending.
    await tester.pump(const Duration(seconds: 6));
  }

  Future<void> showDevicesTab(WidgetTester tester) async {
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
  }

  Finder devicesTabDescendant(Finder matching) =>
      find.descendant(of: find.byType(DevicesTab), matching: matching);

  Finder scanButton() => devicesTabDescendant(
    find.ancestor(of: find.text('Scan'), matching: find.byType(FilledButton)),
  );

  Finder connectButton() => devicesTabDescendant(
    find.ancestor(
      of: find.text('Connect'),
      matching: find.byType(FilledButton),
    ),
  );

  Finder disconnectButton() => devicesTabDescendant(
    find.ancestor(
      of: find.text('Disconnect'),
      matching: find.byType(OutlinedButton),
    ),
  );

  testWidgets('Scan and Connect share width, height, and right edge', (
    tester,
  ) async {
    await pumpApp(tester);
    await showDevicesTab(tester);

    expect(scanButton(), findsOneWidget);
    expect(connectButton(), findsOneWidget);

    final scan = tester.getRect(scanButton());
    final connect = tester.getRect(connectButton());
    expect(scan.width, deviceActionButtonWidth);
    expect(connect.width, deviceActionButtonWidth);
    expect(scan.height, connect.height);
    expect(scan.right, moreOrLessEquals(connect.right, epsilon: 0.01));
  });

  testWidgets('active-row Disconnect keeps the column and the action accent', (
    tester,
  ) async {
    await pumpApp(tester);
    await showDevicesTab(tester);

    // Bring up the demo link (synchronous) so its row renders active.
    await tester.tap(connectButton());
    await tester.pump();

    expect(disconnectButton(), findsOneWidget);
    final scan = tester.getRect(scanButton());
    final disconnect = tester.getRect(disconnectButton());
    expect(disconnect.width, deviceActionButtonWidth);
    expect(disconnect.height, scan.height);
    expect(disconnect.right, moreOrLessEquals(scan.right, epsilon: 0.01));

    // The active row is a plain surface carrying a slate link-state badge;
    // its Disconnect takes the brown action accent (the default OutlinedButton
    // ink), never the state color.
    expect(disconnectButton(), findsOneWidget);
    final scheme = Theme.of(tester.element(disconnectButton())).colorScheme;
    expect(scheme.primary, const Color(0xFF5D4037));
    expect(scheme.primaryContainer, const Color(0xFF455A64));
    expect(devicesTabDescendant(find.text('Connected')), findsOneWidget);

    // Teardown: bring the demo link down so its feed timer stops, then drain
    // the command-queue timeout (see widget_test.dart).
    await tester.tap(disconnectButton());
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('phone width: the buttons move below the title line and keep '
      'the column', (tester) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpApp(tester);
    await showDevicesTab(tester);
    await tester.tap(connectButton());
    await tester.pump();

    expect(disconnectButton(), findsOneWidget);
    final scan = tester.getRect(scanButton());
    final disconnect = tester.getRect(disconnectButton());
    expect(disconnect.width, deviceActionButtonWidth);
    expect(disconnect.right, moreOrLessEquals(scan.right, epsilon: 0.01));

    // Second row: below the device name, not beside it.
    final name = tester.getRect(devicesTabDescendant(find.text('Demo Device')));
    expect(disconnect.top, greaterThan(name.bottom));

    await tester.tap(disconnectButton());
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
  });
}
