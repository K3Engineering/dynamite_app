import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/rig_flash_transport.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/widgets/tare_sheet.dart';

/// The tare sheet: per-channel tare-offset readouts drive masked hub
/// requests, the footer drives the all-channel variants, and a tapped tare
/// offset takes a typed absolute value. No board data here, so the effective
/// unit is raw counts and an untared channel's offset reads 0 ("no offset"
/// is first-class: hub storage is null, the display isn't a sentineled
/// number).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Finder tareOffsetCell(int ch) => find.byKey(Key('tare-offset-$ch'));

  Future<DataHub> openSheet(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    final hub = DataHub();
    final rig = RigState(transport: _FakeTransport(), prefs: prefs);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showTareSheet(
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

  testWidgets('shows one row per active channel, tare offsets', (tester) async {
    final hub = await openSheet(tester);
    feed(hub, 500, 10);
    await tester.pump();

    expect(find.text('Tare'), findsOneWidget);
    expect(find.text('(Raw)'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Tare offset'), findsOneWidget);
    expect(find.text('CH 1'), findsOneWidget);
    expect(find.text('CH 4'), findsOneWidget);
    expect(
      find.text('+0'),
      findsNWidgets(kAdcChannelCount),
    ); // untared: all offsets exactly 0
  });

  testWidgets('per-channel TARE masks the commit; RESET clears per channel', (
    tester,
  ) async {
    final hub = await openSheet(tester);

    await tester.tap(find.byTooltip('Tare this channel').first);
    await tester.pump();
    expect(hub.taring, isTrue);

    feed(hub, 1000, 1000);
    await tester.pump();
    expect(hub.taring, isFalse);
    expect(hub.tare[0], 1000);
    expect(hub.tare[1], isNull);
    // The offset column: CH 1 zeroed out its gross reading, the rest are
    // untared.
    expect(find.text('+1000'), findsOneWidget);
    expect(find.text('+0'), findsNWidgets(kAdcChannelCount - 1));

    await tester.tap(find.byTooltip('Reset this channel').first);
    await tester.pump();
    expect(hub.tare[0], isNull);
    expect(find.text('+0'), findsNWidgets(kAdcChannelCount));
  });

  testWidgets('footer drives the all-channel variants and Close pops', (
    tester,
  ) async {
    final hub = await openSheet(tester);

    await tester.tap(find.text('Tare all'));
    expect(hub.taring, isTrue);
    feed(hub, 700, 1000);
    await tester.pump();
    expect(hub.tare, everyElement(700.0));

    await tester.tap(find.text('Reset all'));
    await tester.pump();
    expect(hub.tare, everyElement(isNull));

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Tare all'), findsNothing);
  });

  testWidgets('tapping a tare offset enters an absolute value', (tester) async {
    final hub = await openSheet(tester);

    await tester.tap(tareOffsetCell(1));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '250');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(hub.tare[1], 250);
    expect(hub.tare[0], isNull);

    // Absolute: re-entering replaces the offset outright.
    await tester.tap(tareOffsetCell(1));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '-75');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(hub.tare[1], -75);

    // The field is gone; the new offset reads back in the cell.
    expect(find.byType(TextField), findsNothing);
    expect(find.text('-75'), findsOneWidget);
  });

  testWidgets(
    'a non-numeric entry stays open with an error and applies nothing',
    (tester) async {
      final hub = await openSheet(tester);

      await tester.tap(tareOffsetCell(0));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('Enter a number'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(hub.tare[0], isNull);
    },
  );

  testWidgets('taring shows in the footer, locks TARE buttons and editing', (
    tester,
  ) async {
    final hub = await openSheet(tester);
    await tester.tap(find.text('Tare all'));
    await tester.pump();

    expect(hub.taring, isTrue);
    expect(find.text('Taring…'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Tare all'))
          .onPressed,
      isNull,
    );

    // Per-channel tare buttons gray out too; the entry field won't open.
    final rowTare = find.ancestor(
      of: find.byTooltip('Tare this channel').first,
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(rowTare).onPressed, isNull);
    await tester.tap(tareOffsetCell(0));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);

    // The window still commits normally afterwards.
    feed(hub, 700, 1000);
    await tester.pump();
    expect(find.text('Taring…'), findsNothing);
    expect(hub.tare[0], 700);
  });
}

/// The sheet reads only the rig's channel titles; the flash transport is
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
