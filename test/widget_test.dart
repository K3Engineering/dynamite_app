import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/main.dart';
import 'package:dynamite_app/models/app_meta.dart';
import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/demo_device.dart';
import 'package:dynamite_app/services/feed_health_tracker.dart';
import 'package:dynamite_app/services/monitor_pause.dart';
import 'package:dynamite_app/services/firmware_catalog.dart';
import 'package:dynamite_app/services/firmware_update_service.dart';
import 'helpers/mockble.dart';
import 'package:dynamite_app/services/recording_controller.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/services/session_metadata.dart';
import 'package:dynamite_app/services/stream_reset_coordinator.dart';

/// Smoke test: pump the real app shell with the production object graph, but
/// with the mock BLE platform installed (so [BleLinkManager]'s startup
/// availability query doesn't need platform channels) and SharedPreferences
/// mocked.
///
/// AppShell uses an IndexedStack, so all four tabs mount at once. The Sessions
/// tab will try to open the session store; on the host there is no platform
/// channel for path_provider, so it surfaces as its in-tree "Error loading
/// sessions" widget — which is fine, we never drive it. We use bounded
/// [WidgetTester.pump] calls rather than pumpAndSettle so that pending real
/// async (the store's root resolution) can't stall the test.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Install the mock so BleLinkManager's unawaited availability query
    // resolves without platform channels.
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.dropEveryNPackets = 0;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    final appEvents = AppEvents();
    final dataHub = DataHub();
    final monitorPause = MonitorPause(dataHub);
    final decoder = AdcPacketDecoder(
      dataHub,
      isPaused: () => monitorPause.paused,
    );
    final prefs = await SharedPreferences.getInstance();
    late final BleLinkManager linkManager;
    final rigState = RigState(
      backend: () => linkManager.backend,
      connectedDeviceName: () => linkManager.connectedDeviceName,
      prefs: prefs,
      events: appEvents,
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
          ChangeNotifierProvider.value(value: monitorPause),
          ChangeNotifierProvider.value(value: rigState),
          ChangeNotifierProvider.value(value: recording),
          ChangeNotifierProvider.value(
            value: FirmwareUpdateService(
              prefs: prefs,
              link: linkManager,
              events: appEvents,
              catalog: GithubReleaseCatalog(),
            ),
          ),
        ],
        child: const DynoApp(),
      ),
    );
    // Settle the first frame: the mock's 200ms availability query fires, and
    // the Sessions stream's MissingPluginException is delivered. We pump past
    // the 5s UniversalBle command-queue timeout too, so its FakeTimer isn't
    // left pending at the end-of-test timer check. (Nothing else schedules
    // timers here — we never connect.)
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets('AppShell renders a five-destination bottom nav', (tester) async {
    await pumpApp(tester);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
  });

  testWidgets('Live tab shows the connect prompt with no device linked', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('Connect a device'), findsOneWidget);
  });

  testWidgets('switching to the Devices tab shows the scan affordance', (
    tester,
  ) async {
    await pumpApp(tester);

    // Devices is the 4th destination (Live, Tests, Sessions, Devices,
    // Settings). Tab activation schedules no async work, so a single frame
    // settles it.
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pump();

    // The Devices tab header is present (also matches the nav label, so
    // findsWidgets), and the Scan toggle button is shown.
    expect(find.text('Devices'), findsWidgets);
    expect(
      find.ancestor(of: find.text('Scan'), matching: find.byType(FilledButton)),
      findsOneWidget,
    );
  });

  testWidgets('Tests tab lists the catalog and opens pre-flight', (
    tester,
  ) async {
    await pumpApp(tester);

    // Tests is the 2nd destination (Live, Tests, Sessions, Devices, Settings).
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pump();

    expect(find.text('Countermovement jump'), findsOneWidget);

    await tester.tap(find.text('Countermovement jump'));
    await tester.pumpAndSettle();

    // Pre-flight shows the title (also matched on the catalog card, which is
    // now covered by the pushed route) and the setup instructions.
    expect(find.text('Countermovement jump'), findsWidgets);
    expect(find.text('Setup'), findsOneWidget);

    // No device is streaming, so Begin is disabled.
    final begin = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Begin'),
    );
    expect(begin.onPressed, isNull);
  });
}
