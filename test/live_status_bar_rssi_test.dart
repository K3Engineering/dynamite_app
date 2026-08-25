import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/screens/live_tab.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/mockble.dart';

/// Widget test for the Live status bar's RSSI readout against the mock BLE
/// platform: hidden while no reading exists (not streaming / first poll not
/// landed — and forever on web or the demo device), shown once a poll lands,
/// placed left of the "1000 Hz" label, and hidden again after teardown.
///
/// Timing (see ble_link_manager_test.dart): mock connect + post-connect setup
/// takes ~3 s; the poller's first tick lands [BleLinkManager.rssiPollInterval]
/// (2 s) after streaming starts. Everything runs on the widget test's fake
/// clock, advanced with bounded [WidgetTester.pump] calls. The link is
/// disconnected at the end so the periodic poll timer (and the mock's
/// notification timers) are never left pending.
void main() {
  const deviceId = '2';

  setUp(() {
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.resetKnobs();
  });

  testWidgets('Live status bar shows polled RSSI left of the Hz label', (
    tester,
  ) async {
    final link = BleLinkManager(events: AppEvents())
      ..onCalibrationData = (_, _) {};

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: link,
        child: MaterialApp(
          home: Scaffold(
            body: LiveStatusBar(
              isConnected: true,
              connectedDeviceName: 'K3',
              sampleRateHz: 1000,
              onGoToDevices: () {},
            ),
          ),
        ),
      ),
    );

    // Link not streaming yet: no reading can exist — nothing renders.
    expect(find.textContaining('dBm'), findsNothing);

    unawaited(link.connectToDevice(deviceId));
    await tester.pump(); // kick the connect off
    // Advance in half-second steps until streaming starts (bounded) rather
    // than hardcoding the mock's connect+setup duration — it shifted once
    // already when the connect flow was reworked.
    for (var i = 0; i < 8 && !link.isStreaming; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(link.isStreaming, isTrue);

    // Streaming just started, so the first poll tick (2 s later) hasn't
    // landed yet — still hidden.
    expect(find.textContaining('dBm'), findsNothing);

    // First poll tick (2s after streaming): the readout appears…
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('1 dBm'), findsOneWidget); // the mock's fixed reading

    // …left of the sample-rate label.
    final rssiLeft = tester.getTopLeft(find.text('1 dBm')).dx;
    final hzLeft = tester.getTopLeft(find.text('1000 Hz')).dx;
    expect(rssiLeft, lessThan(hzLeft));

    // Teardown: end the streaming link so the periodic poll timer is
    // cancelled, then settle past the mock's disconnect AND the command
    // queue's 5s timeouts so nothing is left pending at the end-of-test
    // timer check.
    unawaited(link.disconnectSelectedDevice());
    await tester.pump(const Duration(seconds: 8));
    expect(link.isStreaming, isFalse);
    expect(find.textContaining('dBm'), findsNothing);
  });
}
