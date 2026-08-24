import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/rig_flash_transport.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/widgets/rig_slots_section.dart';

/// Widget tests for the rig slot section: rows from the device flash doc,
/// the add/edit dialogs, and the dirty banner. The harness hands the
/// section a real [RigState] (fake transport) with a flash doc already
/// read. Save behavior itself is covered in rig_state_test.dart.
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

  @override
  Future<String?> readFlashDoc() async => lastWrittenDoc;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<RigState> pump(WidgetTester tester, {bool withFlash = true}) async {
    SharedPreferences.setMockInitialValues({});
    final rig = RigState(
      transport: _FakeTransport(),
      // The rig's prefs load is synchronous in the constructor, so reading
      // the flash right after construction is fine.
      prefs: await SharedPreferences.getInstance(),
    );
    if (withFlash) {
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        DeviceFlash.parse(
          demoBoardCalibrationDoc,
          pgaGains: const [1, 1, 1, 1],
        ),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: RigSlotsSection(rig: rig)),
        ),
      ),
    );
    await tester.pumpAndSettle();
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
    expect(
      find.text('Settings shown are read from the device.'),
      findsOneWidget,
    );
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

    // A history tap pre-fills the fields; the Save button commits.
    await tester.ensureVisible(inDialog(find.text('Thrust cell')));
    await tester.pump();
    await tester.tap(inDialog(find.text('Thrust cell')));
    await tester.pump();
    await tester.tap(inDialog(find.widgetWithText(FilledButton, 'Save')));
    await tester.pumpAndSettle();

    expect(rig.hasPending, isTrue);
    expect(rig.channelCells[3]?.name, 'Thrust cell');
    expect(find.textContaining('Changes not saved to device'), findsOneWidget);
    // Dirty: the Save button is live (the section only renders while
    // connected — the pending session dies with the link).
    final saveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save to device'),
    );
    expect(saveButton.onPressed, isNotNull);

    // Revert restores the flash state and returns the bar to clean.
    await tester.tap(find.text('Revert'));
    await tester.pumpAndSettle();
    expect(rig.hasPending, isFalse);
    expect(rig.channelCells[3], isNull);
    expect(find.textContaining('Changes not saved to device'), findsNothing);
    expect(
      find.text('Settings shown are read from the device.'),
      findsOneWidget,
    );
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
    expect(find.textContaining('250 kg · 2.0004 mV/V'), findsOneWidget);
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

  testWidgets('add dialog carries the fields; a history tap pre-fills them', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.text('Empty slot').first);
    await tester.pumpAndSettle();

    // Fields and history in one dialog — no second window.
    expect(inDialog(find.text('Add load cell — CH 4')), findsOneWidget);
    expect(
      inDialog(find.widgetWithText(TextField, 'Capacity (kg)')),
      findsOneWidget,
    );
    expect(inDialog(find.text('Last seen in this app')), findsOneWidget);
    expect(find.text('Custom entry…'), findsNothing);
    expect(find.text('New load cell — CH 4'), findsNothing);

    FilledButton saveButton() => tester.widget<FilledButton>(
      inDialog(find.widgetWithText(FilledButton, 'Save')),
    );
    TextField field(String label) => tester.widget<TextField>(
      inDialog(find.widgetWithText(TextField, label)),
    );

    // Save stays off until a capacity AND a sensitivity parse positive…
    expect(saveButton().onPressed, isNull);

    // …a history tap fills them in (Thrust cell: 200 kg, 1.9993 mV/V).
    await tester.ensureVisible(inDialog(find.text('Thrust cell')));
    await tester.pump();
    await tester.tap(inDialog(find.text('Thrust cell')));
    await tester.pump();
    expect(saveButton().onPressed, isNotNull);
    expect(field('Name (optional)').controller!.text, 'Thrust cell');
    expect(field('Capacity (kg)').controller!.text, '200');
    expect(
      field('Sensitivity (mV/V at full scale)').controller!.text,
      '1.9993',
    );
  });
}
