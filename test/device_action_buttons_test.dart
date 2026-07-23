import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/main.dart';
import 'package:dynamite_app/models/app_settings.dart';
import 'package:dynamite_app/screens/devices_tab.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/mockble.dart';
import 'package:dynamite_app/services/recording_controller.dart';

/// Layout contract for the Devices tab's action buttons: Scan/Stop (status
/// row), Connect (inactive rows) and Cancel/Disconnect (active row) all share
/// [deviceActionButtonWidth] and one right-edge column, and the active row's
/// outlined button takes the row's content color (the gear/title's
/// onPrimaryContainer) for its outline and label, dimmed while disabled.
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
    find.ancestor(of: find.text('Connect'), matching: find.byType(FilledButton)),
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

  testWidgets('active-row Disconnect keeps the column and the row colors', (
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

    // Outline + label take the row's content color (light theme: white),
    // dimmed to half alpha while teardown is in flight (disabled).
    final style = tester.widget<OutlinedButton>(disconnectButton()).style!;
    final enabled = style.side!.resolve(<WidgetState>{})!;
    final disabled = style.side!.resolve(<WidgetState>{WidgetState.disabled})!;
    expect(enabled.color, Colors.white);
    expect(disabled.color, Colors.white.withValues(alpha: 0.5));
    expect(
      style.foregroundColor!.resolve(<WidgetState>{}),
      Colors.white,
    );

    // Teardown: bring the demo link down so its feed timer stops, then drain
    // the command-queue timeout (see widget_test.dart).
    await tester.tap(disconnectButton());
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
  });
}
