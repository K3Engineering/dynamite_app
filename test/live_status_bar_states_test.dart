import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/bt_scan.dart';
import 'package:dynamite_app/screens/live_tab.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/mockble.dart';

/// The Live tab's disconnected surfaces, driven by the link state:
///
///  * The status bar is a pure readout: a neutral strip for idle and every
///    in-flight state (with the stage label shared with the Devices tab),
///    and never a connect affordance ("tap to connect" is gone).
///  * The prompt's only action is the idle "Connect a device" CTA; during
///    a connect/disconnect it names the device and shows nothing tappable.
void main() {
  setUp(() {
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.resetKnobs();
  });

  Widget host(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  LiveStatusBar bar(BtLinkState state) => LiveStatusBar(
    linkState: state,
    connectedDeviceName: 'K3',
    sampleRateHz: 1000,
  );

  Color barColor(WidgetTester tester) {
    return tester
        .widget<Container>(
          find.descendant(
            of: find.byType(LiveStatusBar),
            matching: find.byType(Container),
          ),
        )
        .color!;
  }

  ColorScheme schemeOf(WidgetTester tester, Type widgetType) =>
      Theme.of(tester.element(find.byType(widgetType))).colorScheme;

  group('LiveStatusBar', () {
    testWidgets('idle is a neutral readout with no connect affordance', (
      tester,
    ) async {
      await tester.pumpWidget(host(bar(BtLinkState.idle)));
      final scheme = schemeOf(tester, LiveStatusBar);
      expect(barColor(tester), scheme.surfaceContainerHighest);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.textContaining('tap to connect'), findsNothing);
    });

    testWidgets('in-flight states show the shared stage label, neutral', (
      tester,
    ) async {
      final cases = [
        (BtLinkState.connecting, 'Connecting…'),
        (BtLinkState.connected, 'Setting up…'),
        (BtLinkState.readingConstants, 'Reading board constants…'),
        (BtLinkState.subscribing, 'Starting data stream…'),
        (BtLinkState.disconnecting, 'Disconnecting…'),
      ];
      for (final (state, label) in cases) {
        await tester.pumpWidget(host(bar(state)));
        final scheme = schemeOf(tester, LiveStatusBar);
        expect(find.text(label), findsOneWidget, reason: '$state');
        expect(barColor(tester), scheme.surfaceContainerHighest);
      }
    });

    testWidgets('streaming keeps the tinted connected strip', (tester) async {
      // Only the streaming layout needs the manager (the RSSI indicator's
      // select); constructing it starts the adapter-state query, so settle
      // past the mock's + the command queue's timeouts at the end.
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: BleLinkManager(events: AppEvents())
            ..onCalibrationData = (_, _) {},
          child: host(bar(BtLinkState.streaming)),
        ),
      );
      final scheme = schemeOf(tester, LiveStatusBar);
      expect(barColor(tester), scheme.primaryContainer);
      expect(find.text('Connected: K3'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('DisconnectedPrompt', () {
    DisconnectedPrompt prompt(BtLinkState state, VoidCallback onConnect) =>
        DisconnectedPrompt(
          linkState: state,
          deviceName: 'K3',
          onConnect: onConnect,
        );

    testWidgets('idle: title plus the single connect CTA', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        host(prompt(BtLinkState.idle, () => tapped = true)),
      );
      expect(find.text('No device connected'), findsOneWidget);
      await tester.tap(find.byType(FilledButton));
      expect(tapped, isTrue);
    });

    testWidgets('in-flight: names the device, shows nothing tappable', (
      tester,
    ) async {
      final states = {
        for (final s in BtLinkState.values)
          if (s != BtLinkState.idle && s != BtLinkState.streaming) s,
      };
      for (final state in states) {
        await tester.pumpWidget(host(prompt(state, () {})));
        expect(
          find.text(
            state == BtLinkState.disconnecting
                ? 'Disconnecting from K3…'
                : 'Connecting to K3…',
          ),
          findsOneWidget,
          reason: '$state',
        );
        expect(find.byType(FilledButton), findsNothing, reason: '$state');
      }
    });
  });
}
