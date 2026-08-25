import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kLongPressTimeout;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/rig_flash_transport.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/screens/rig_slots_section.dart';

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
    // The rotated tags on the four channel rows (in the rail cells).
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

  testWidgets('large text scale: rows grow, tags stay centered on them', (
    tester,
  ) async {
    await pump(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump();

    // Clipped or overflowed content would surface as an exception here.
    expect(tester.takeException(), isNull);
    for (int i = 1; i <= 4; ++i) {
      expect(find.text('CH $i'), findsOneWidget);
    }

    // The row grew past a two-line tile's default height instead of
    // clipping…
    final row = find.ancestor(
      of: find.text('Thrust cell'),
      matching: find.byType(ListTile),
    );
    expect(tester.getRect(row).height, greaterThan(72));

    // …and its CH tag is still centered on the row itself, not on a stale
    // height constant.
    final tag = find.ancestor(
      of: find.text('CH 1'),
      matching: find.byType(RotatedBox),
    );
    expect(
      (tester.getCenter(tag).dy - tester.getRect(row).center.dy).abs(),
      lessThan(4),
    );
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

  void expectSwapped(RigState rig) {
    expect(rig.effectiveSlots.cellAt(1)?.name, 'Spare 50');
    expect(rig.effectiveSlots.cellAt(4)?.name, 'Break jig');
    // A swap is a pending edit: the dirty state of the bar is up.
    expect(rig.hasPending, isTrue);
    expect(find.textContaining('Changes not saved to device'), findsOneWidget);
  }

  testWidgets('desktop: a mouse drag anywhere on a row swaps it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final rig = await pump(tester);

    // Press in the middle of the 'Break jig' row (slot 1, CH2) — not on the
    // grip icon — and drag three rows down onto 'Spare 50' (slot 4).
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Break jig')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 3 * 72));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expectSwapped(rig);
    // The binding's invariant check rejects a leftover override (it runs
    // before tearDowns), so reset in the test body.
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('touch: tap-and-hold drags; a quick flick scrolls instead', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final rig = await pump(tester);

    // A quick vertical flick on the row scrolls the page; it must not start
    // a drag (the drag needs a settled hold first).
    final flick = await tester.startGesture(
      tester.getCenter(find.text('Break jig')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await flick.moveBy(const Offset(0, -200));
    await flick.up();
    await tester.pumpAndSettle();
    expect(rig.effectiveSlots.cellAt(1)?.name, 'Break jig');
    expect(rig.hasPending, isFalse);

    // Tap-and-hold on 'Break jig' (slot 1, CH2), then drag three rows down
    // onto 'Spare 50' (slot 4).
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Break jig')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 3 * 72));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expectSwapped(rig);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('drag hover highlight does not grow or shift rows', (
    tester,
  ) async {
    await pump(tester);

    // The hover target's AnimatedContainer ('Spare 50', slot 4) and the
    // topmost empty row below it, measured before the drag.
    final target = find.ancestor(
      of: find.text('Spare 50'),
      matching: find.byType(AnimatedContainer),
    );
    final below = find.ancestor(
      of: find.text('Empty slot').first,
      matching: find.byType(AnimatedContainer),
    );
    final targetBefore = tester.getRect(target);
    final belowBefore = tester.getRect(below);

    // Drag the 'Break jig' row (slot 1) down over 'Spare 50' and HOLD it
    // there: startGesture keeps the drag in flight so the target stays
    // highlighted (tester.drag would drop immediately). Touch drag starts
    // on tap-and-hold, so settle first.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Break jig')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 3 * 72));
    await tester.pump();
    // Run the 120ms highlight animation to completion.
    await tester.pump(const Duration(milliseconds: 200));

    // The target really is highlighted — otherwise the height assertions
    // below would be vacuous. (The border lives in foregroundDecoration;
    // checking both slots keeps the assertion about the highlight, not
    // about which decoration carries it.)
    final container = tester.widget<AnimatedContainer>(target);
    final highlight =
        (container.foregroundDecoration ?? container.decoration)
            as BoxDecoration?;
    expect(highlight?.border, isNotNull);

    // Regression: the highlighted row keeps its height and the list below
    // it does not shift — a border in `decoration` would become layout
    // padding and grow the row.
    expect(tester.getRect(target).height, targetBefore.height);
    expect(tester.getRect(below).top, belowBefore.top);

    await gesture.up();
    await tester.pumpAndSettle();
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
