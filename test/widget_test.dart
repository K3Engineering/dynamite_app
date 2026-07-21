import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/main.dart';
import 'package:dynamite_app/models/app_settings.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/mockble.dart';
import 'package:dynamite_app/services/recording_controller.dart';

/// Smoke test: pump the real app shell with the production object graph, but
/// with the mock BLE platform installed (so [BleLinkManager]'s startup
/// availability query doesn't need platform channels) and SharedPreferences
/// mocked.
///
/// AppShell uses an IndexedStack, so all four tabs mount at once. The Sessions
/// tab will try to open the drift database; on the host there are no platform
/// channels for path_provider/sqlite, so it surfaces as its in-tree "Error
/// loading sessions" widget — which is fine, we never drive it. We use bounded
/// [WidgetTester.pump] calls rather than pumpAndSettle so that pending real
/// async (the drift connection future) can't stall the test.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Install the mock regardless of useMockBt so BleLinkManager's unawaited
    // availability query resolves without platform channels.
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.dropEveryNPackets = 0;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    final appEvents = AppEvents();
    final dataHub = DataHub();
    final decoder = AdcPacketDecoder(dataHub);
    final linkManager = BleLinkManager(events: appEvents)
      ..onAdcData = decoder.onDataPacket
      ..onCalibrationData = decoder.onCalibrationPacket;
    final recording = RecordingController(
      dataHub: dataHub,
      linkManager: linkManager,
      decoder: decoder,
      events: appEvents,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppSettings()),
          Provider.value(value: appEvents),
          ChangeNotifierProvider.value(value: dataHub),
          ChangeNotifierProvider.value(value: linkManager),
          ChangeNotifierProvider.value(value: recording),
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

  testWidgets('AppShell renders a four-destination bottom nav', (tester) async {
    await pumpApp(tester);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(4));
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

    // Devices is the 3rd destination (Live, Sessions, Devices, Settings).
    // Activating it fires requestEnableBluetooth() from a post-frame
    // callback, so first pump one frame to let that callback schedule its
    // timers, then pump past the mock's 200ms hwDelay AND universal_ble's 5s
    // command-queue timeout so neither is left pending at the end-of-test
    // check. (A single pump(6s) would advance the clock BEFORE the frame that
    // creates the timers, leaving them pending.)
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));

    // The Devices tab header is present (also matches the nav label, so
    // findsWidgets), and the Scan toggle button is shown.
    expect(find.text('Devices'), findsWidgets);
    expect(
      find.ancestor(of: find.text('Scan'), matching: find.byType(FilledButton)),
      findsOneWidget,
    );
  });
}
