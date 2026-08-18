import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/main.dart';
import 'package:dynamite_app/models/app_meta.dart';
import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/models/device_info.dart';
import 'package:dynamite_app/screens/devices_tab.dart';
import 'package:dynamite_app/screens/settings_tab.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/demo_device.dart';
import 'package:dynamite_app/services/feed_health_tracker.dart';
import 'package:dynamite_app/services/mockble.dart';
import 'package:dynamite_app/services/recording_controller.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/widgets/info_cards.dart';

/// Device identity (Device Information service) display. The card's own
/// rendering is covered with a standalone harness; the two surfaces it feeds
/// in the real app shell — the Devices tab's active-row subtitle and the
/// Settings tab's "Device info" section — are exercised end-to-end with the
/// demo device, whose synthetic identity is set synchronously at connect (no
/// scan timing involved). Full-app harness: same pattern as
/// device_action_buttons_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceInfoCard', () {
    Future<void> pumpCard(WidgetTester tester, DeviceInfo? info) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DeviceInfoCard(info: info)),
        ),
      );
    }

    testWidgets('renders all five identity fields', (tester) async {
      await pumpCard(
        tester,
        const DeviceInfo(
          manufacturer: 'K3 Engineering',
          model: 'Dynamite Sampler Pro Mk1',
          serial: 'A4CF1208F51E',
          hardwareRev: 'v700P',
          firmwareRev: 'v700P|v1.2.3',
        ),
      );

      expect(find.text('Dynamite Sampler Pro Mk1'), findsOneWidget);
      expect(find.text('v700P'), findsOneWidget);
      expect(find.text('v700P|v1.2.3'), findsOneWidget);
      expect(find.text('A4CF1208F51E'), findsOneWidget);
      expect(find.text('K3 Engineering'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('nulls render as em dashes, never made-up values', (
      tester,
    ) async {
      // The read hasn't landed yet (or the device was just connected).
      await pumpCard(tester, null);
      expect(find.text('—'), findsNWidgets(5));

      // The web case: only the serial is unreadable (0x2A25 blocklist).
      await pumpCard(
        tester,
        const DeviceInfo(
          manufacturer: 'K3 Engineering',
          model: 'Dynamite Sampler Pro Mk1',
          hardwareRev: 'v700P',
          firmwareRev: 'v700P|v1.2.3',
        ),
      );
      expect(find.text('—'), findsOneWidget);
      expect(find.text('Dynamite Sampler Pro Mk1'), findsOneWidget);
    });
  });

  group('app shell surfaces (demo device)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      UniversalBle.setInstance(MockBlePlatform.instance);
      MockBlePlatform.instance.dropEveryNPackets = 0;
    });

    Future<BleLinkManager> pumpApp(WidgetTester tester) async {
      final appEvents = AppEvents();
      final dataHub = DataHub();
      final decoder = AdcPacketDecoder(dataHub);
      final linkManager = BleLinkManager(events: appEvents, demo: DemoDevice())
        ..onAdcData = decoder.onDataPacket
        ..onCalibrationData = decoder.onCalibrationPacket;
      final prefs = await SharedPreferences.getInstance();
      final rigState = RigState(transport: linkManager, prefs: prefs);
      decoder.onDeviceFlash = (flash) => rigState.onFlashRead(
        linkManager.connectedDeviceId,
        linkManager.connectedDeviceName,
        flash,
      );
      final recording = RecordingController(
        dataHub: dataHub,
        linkManager: linkManager,
        decoder: decoder,
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
      // See widget_test.dart: settle the mock's startup round-trips AND the
      // 5s universal_ble command-queue timeout so no timer is left pending.
      await tester.pump(const Duration(seconds: 6));
      return linkManager;
    }

    Finder devicesTabDescendant(Finder matching) =>
        find.descendant(of: find.byType(DevicesTab), matching: matching);

    /// Bring up the demo link from the Devices tab (synchronous connect, so
    /// a single pump after the tap shows the active row).
    Future<void> connectDemo(WidgetTester tester) async {
      await tester.tap(find.byType(NavigationDestination).at(2));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      await tester.tap(
        devicesTabDescendant(
          find.ancestor(
            of: find.text('Connect'),
            matching: find.byType(FilledButton),
          ),
        ),
      );
      await tester.pump();
    }

    /// Bring the demo link down so its feed timer stops, then drain the
    /// command-queue timeout (see widget_test.dart).
    Future<void> teardownDemo(WidgetTester tester, BleLinkManager link) async {
      await link.disconnectSelectedDevice();
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
    }

    testWidgets('Devices tab active row shows the model in its subtitle', (
      tester,
    ) async {
      final link = await pumpApp(tester);
      await connectDemo(tester);

      expect(
        devicesTabDescendant(
          find.text('Connected • Dynamite Sampler Demo', findRichText: true),
        ),
        findsOneWidget,
      );

      await teardownDemo(tester, link);
    });

    testWidgets('Settings tab shows the device info card for the connected '
        'device', (tester) async {
      final link = await pumpApp(tester);
      await connectDemo(tester);

      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pump();

      // The device section sits below the fold; the settings ListView
      // builds children lazily, so scroll the card into view first
      // (IndexedStack keeps every tab's Scrollable in the tree — target
      // the settings one explicitly).
      await tester.scrollUntilVisible(
        find.text('Dynamite Sampler Demo'),
        300,
        scrollable: find.descendant(
          of: find.byType(SettingsTab),
          matching: find.byType(Scrollable),
        ),
      );

      expect(find.text('Device info'), findsOneWidget);
      expect(find.text('Dynamite Sampler Demo'), findsOneWidget);
      expect(find.text('DEMO00000000'), findsOneWidget);
      // The demo identity is complete: no dash placeholders.
      expect(
        find.descendant(
          of: find.byType(DeviceInfoCard),
          matching: find.text('—'),
        ),
        findsNothing,
      );

      await teardownDemo(tester, link);
    });

    testWidgets('Settings tab shows connection info without ATT MTU', (
      tester,
    ) async {
      final link = await pumpApp(tester);
      await connectDemo(tester);
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Connection info'),
        300,
        scrollable: find.descendant(
          of: find.byType(SettingsTab),
          matching: find.byType(Scrollable),
        ),
      );

      expect(find.text('Connection info'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ConnectionInfoCard),
          matching: find.text('ATT MTU'),
        ),
        findsNothing,
      );
      expect(find.text('Min packet size'), findsOneWidget);
      expect(find.text('Max packet size'), findsOneWidget);
      expect(find.text('242 B'), findsNWidgets(2));

      await teardownDemo(tester, link);
    });
  });
}
