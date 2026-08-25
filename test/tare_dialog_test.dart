import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/rig_flash_transport.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/widgets/tare_dialog.dart';

/// The tare dialog: per-channel live/tare readouts drive masked hub requests,
/// and the footer drives the all-channel variants. No board data here, so the
/// effective unit is raw counts and values equal tare-adjusted counts.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<DataHub> openDialog(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    final hub = DataHub();
    final rig = RigState(transport: _FakeTransport(), prefs: prefs);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showTareDialog(
                context,
                hub: hub,
                rig: rig,
                settings: AppSettings(prefs: prefs),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return hub;
  }

  void feed(DataHub hub, int value, int count) {
    final frame = Int32List(kAdcChannelCount)
      ..fillRange(0, kAdcChannelCount, value);
    // Mimic the decoder: samples, then a per-packet commit (the notify).
    final start = hub.totalSamples;
    for (int i = 0; i < count; i++) {
      hub.addSampleFrame(frame);
    }
    hub.commitBatch(start);
  }

  testWidgets('shows one row per active channel, live and tare values', (
    tester,
  ) async {
    final hub = await openDialog(tester);
    feed(hub, 500, 10);
    await tester.pump();

    expect(find.text('Tare · Raw'), findsOneWidget);
    expect(find.text('CH 1'), findsOneWidget);
    expect(find.text('CH 4'), findsOneWidget);
    expect(find.text('+500'), findsNWidgets(kAdcChannelCount)); // live
    expect(
      find.text('+0'),
      findsNWidgets(kAdcChannelCount),
    ); // untared: all tare points 0
  });

  testWidgets('per-channel TARE masks the commit; RESET clears per channel', (
    tester,
  ) async {
    final hub = await openDialog(tester);

    await tester.tap(find.byTooltip('Tare this channel').first);
    await tester.pump();
    expect(hub.taring, isTrue);

    feed(hub, 1000, 1000);
    await tester.pump();
    expect(hub.taring, isFalse);
    expect(hub.tare[0], 1000);
    expect(hub.tare[1], 0);
    // Live: CH 1 nets to 0, the rest read gross. Tare column: CH 1 only.
    expect(find.text('+0'), findsNWidgets(kAdcChannelCount));
    expect(find.text('+1000'), findsNWidgets(kAdcChannelCount));

    await tester.tap(find.byTooltip('Reset this channel').first);
    await tester.pump();
    expect(hub.tare[0], 0);
  });

  testWidgets('footer drives the all-channel variants and Close pops', (
    tester,
  ) async {
    final hub = await openDialog(tester);

    await tester.tap(find.text('Tare all'));
    expect(hub.taring, isTrue);
    feed(hub, 700, 1000);
    await tester.pump();
    expect([...hub.tare], [700.0, 700.0, 700.0, 700.0]);

    await tester.tap(find.text('Reset all'));
    await tester.pump();
    expect([...hub.tare], [0.0, 0.0, 0.0, 0.0]);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Tare all'), findsNothing);
  });
}

/// The dialog reads only the rig's channel titles; the flash transport is
/// never exercised.
class _FakeTransport implements RigFlashTransport {
  @override
  String get connectedDeviceId => 'dev1';
  @override
  String get connectedDeviceName => 'Bench unit';
  @override
  Future<void> writeFlashDoc(String doc) async {}
  @override
  Future<String?> readFlashDoc() async => null;
}
