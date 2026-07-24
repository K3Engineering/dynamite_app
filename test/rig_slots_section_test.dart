import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/mockble.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/widgets/rig_slots_section.dart';

/// Widget tests for the rig slot section: rows from the device flash doc,
/// the add/edit dialogs, and the dirty banner. The BLE link manager is real
/// (mock platform) but never connected, so the Save button stays disabled —
/// save logic itself is covered in rig_state_test.dart.
class _FakeTransport implements RigFlashTransport {
  String? lastWrittenDoc;

  @override
  String get connectedDeviceId => 'dev1';

  @override
  String get connectedDeviceName => 'Bench unit';

  @override
  Future<void> writeFlashDoc(String doc) async {
    lastWrittenDoc = doc;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<RigState> pump(WidgetTester tester, {bool withFlash = true}) async {
    SharedPreferences.setMockInitialValues({});
    UniversalBle.setInstance(MockBlePlatform.instance);
    final events = AppEvents();
    final link = BleLinkManager(events: events);
    // NOTE: no async settle delay here — inside testWidgets the clock is
    // FakeAsync and a Future.delayed would never fire. The rig's async
    // prefs load is harmless (empty prefs) and race-free (modified-keys
    // guard), so reading the flash right after construction is fine.
    final rig = RigState(transport: _FakeTransport(), events: events);
    if (withFlash) {
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        DeviceFlash.parse(demoBoardCalibrationDoc),
      );
    }
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RigState>.value(value: rig),
          ChangeNotifierProvider<BleLinkManager>.value(value: link),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: RigSlotsSection())),
        ),
      ),
    );
    // Pump past the construction-time BLE timers (the mock's 200ms
    // availability query and universal_ble's 5s command-queue timeout) so
    // none are left pending at the end-of-test timer check — same pattern
    // as widget_test.dart.
    await tester.pump(const Duration(seconds: 6));
    return rig;
  }

  Finder inDialog(Finder matching) =>
      find.descendant(of: find.byType(AlertDialog), matching: matching);

  testWidgets('no flash doc: placeholder card', (tester) async {
    await pump(tester, withFlash: false);
    expect(find.text('No slot data from the device'), findsOneWidget);
  });

  testWidgets('rows render the device slots with channel tags', (tester) async {
    await pump(tester);

    expect(find.text('Thrust cell'), findsOneWidget);
    expect(find.text('Break jig'), findsOneWidget);
    // Unnamed CH3 cell: its title AND subtitle both render the values line.
    expect(find.text('100 kg · 2 mV/V'), findsNWidgets(2));
    expect(find.text('Spare 50'), findsOneWidget); // the spare
    expect(find.text('Empty slot'), findsNWidgets(6));
    // The rotated tags on the four channel rows (in the static gutter).
    for (int i = 1; i <= 4; ++i) {
      expect(find.text('CH $i'), findsOneWidget);
    }
    // Nothing dirty yet: the status bar shows its clean state.
    expect(find.text('All settings saved to device.'), findsOneWidget);
    expect(find.textContaining('Changes not saved to device'), findsNothing);
  });

  testWidgets('add from history fills the slot and raises the dirty banner', (
    tester,
  ) async {
    final rig = await pump(tester);

    await tester.tap(find.text('Empty slot').first);
    await tester.pumpAndSettle();
    expect(inDialog(find.text('Add load cell — CH 4')), findsOneWidget);
    expect(inDialog(find.text('Last seen in this app')), findsOneWidget);

    await tester.tap(inDialog(find.text('Thrust cell')));
    await tester.pumpAndSettle();

    expect(rig.hasPending, isTrue);
    expect(rig.channelCells[3]?.name, 'Thrust cell');
    expect(find.textContaining('Changes not saved to device'), findsOneWidget);
    // Offline (no connected device): Save is disabled.
    final saveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save to device'),
    );
    expect(saveButton.onPressed, isNull);

    // Revert restores the flash state and returns the bar to clean.
    await tester.tap(find.text('Revert'));
    await tester.pumpAndSettle();
    expect(rig.hasPending, isFalse);
    expect(rig.channelCells[3], isNull);
    expect(find.textContaining('Changes not saved to device'), findsNothing);
    expect(find.text('All settings saved to device.'), findsOneWidget);
  });

  testWidgets('dragging a slot onto another swaps them', (tester) async {
    final rig = await pump(tester);

    // The drag handle inside the 'Break jig' row (slot 1, CH2).
    final handle = find.descendant(
      of: find.ancestor(
        of: find.text('Break jig'),
        matching: find.byType(ListTile),
      ),
      matching: find.byIcon(Icons.drag_indicator),
    );
    expect(handle, findsOneWidget);

    // Drag it three rows down onto 'Spare 50' (slot 4).
    await tester.drag(handle, const Offset(0, 3 * 72));
    await tester.pump();

    expect(rig.effectiveSlots.cellAt(1)?.name, 'Spare 50');
    expect(rig.effectiveSlots.cellAt(4)?.name, 'Break jig');
    // A swap is a pending edit: the dirty state of the bar is up.
    expect(rig.hasPending, isTrue);
    expect(find.textContaining('Changes not saved to device'), findsOneWidget);
  });

  testWidgets('edit a populated slot via the editor', (tester) async {
    final rig = await pump(tester);

    await tester.tap(find.text('Break jig'));
    await tester.pumpAndSettle();
    expect(inDialog(find.text('Edit load cell — CH 2')), findsOneWidget);

    await tester.enterText(
      inDialog(find.widgetWithText(TextField, 'Capacity (kg)')),
      '250',
    );
    await tester.pump();
    await tester.tap(inDialog(find.widgetWithText(FilledButton, 'Save')));
    await tester.pumpAndSettle();

    expect(rig.hasPending, isTrue);
    expect(rig.channelCells[1]?.capacityKg, 250);
    expect(rig.channelCells[1]?.name, 'Break jig'); // name untouched
    expect(find.textContaining('250 kg · 2 mV/V'), findsOneWidget);
  });

  testWidgets('clear slot empties it', (tester) async {
    final rig = await pump(tester);

    await tester.tap(find.text('Break jig'));
    await tester.pumpAndSettle();
    await tester.tap(inDialog(find.text('Clear slot')));
    await tester.pumpAndSettle();

    expect(rig.channelCells[1], isNull);
    expect(find.text('Empty slot'), findsNWidgets(7));
  });

  testWidgets('custom entry from the add dialog opens the editor', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.text('Empty slot').first);
    await tester.pumpAndSettle();
    await tester.tap(inDialog(find.text('Custom entry…')));
    await tester.pumpAndSettle();

    expect(inDialog(find.text('New load cell — CH 4')), findsOneWidget);
  });
}
