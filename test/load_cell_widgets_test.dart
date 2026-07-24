import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/app_settings.dart';
import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/widgets/load_cell_picker.dart';

/// Widget tests for the load cell bank section and the per-channel
/// assignment flow (isolated from the BLE stack: these widgets depend on
/// [AppSettings] only).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppSettings> pump(WidgetTester tester, Widget child) async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettings();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  testWidgets('bank section: add a cell via the editor', (tester) async {
    await pump(tester, const LoadCellBankSection());
    expect(find.textContaining('No saved load cells'), findsOneWidget);

    await tester.tap(find.text('Add load cell'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Capacity (kg)'),
      '200',
    );
    await tester.pump(); // revalidate enables Save
    await tester.enterText(
      find.widgetWithText(TextField, 'Sensitivity (mV/V at full scale)'),
      '2',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('200 kg · 2 mV/V'), findsOneWidget);
  });

  testWidgets('quick chips fill the editor; unnamed save dedupes generics', (
    tester,
  ) async {
    final settings = await pump(tester, const LoadCellBankSection());

    Future<void> createViaChips() async {
      await tester.tap(find.text('Add load cell'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('200 kg'));
      await tester.pump(); // rebuild with the filled field enables Save
      await tester.tap(find.text('2 mV/V'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    await createViaChips();
    await createViaChips(); // identical: deduped, not duplicated
    expect(settings.loadCellBank, hasLength(1));
    expect(settings.loadCellBank.single.name, isEmpty);
    expect(find.text('200 kg · 2 mV/V'), findsOneWidget);
  });

  testWidgets('assign a bank profile to a channel', (tester) async {
    final settings = await pump(tester, const ChannelLoadCellAssignments());
    await settings.saveLoadCell(
      LoadCellProfile(
        id: 'gold',
        name: 'Golden cell',
        capacityKg: 100,
        sensitivityMvV: 2.0123,
      ),
    );
    await tester.pump();

    // Every channel starts unassigned.
    expect(find.text('No load cell — electrical units only'), findsNWidgets(4));

    await tester.tap(find.text('Ch 1 · Load Cell 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Golden cell'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assign'));
    await tester.pumpAndSettle();

    expect(settings.channelLoadCellIds[0], 'gold');
    expect(find.text('Golden cell — 100.0 kg · 2.0123 mV/V'), findsOneWidget);
    expect(find.text('No load cell — electrical units only'), findsNWidgets(3));
  });

  testWidgets('assign "None" explicitly clears a channel', (tester) async {
    final settings = await pump(tester, const ChannelLoadCellAssignments());
    await settings.saveLoadCell(
      LoadCellProfile(id: 'a', capacityKg: 100, sensitivityMvV: 2),
    );
    await settings.assignLoadCell(0, 'a');
    await tester.pump();

    await tester.tap(find.text('Ch 1 · Load Cell 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assign'));
    await tester.pumpAndSettle();

    expect(settings.channelLoadCellIds[0], isNull);
  });

  testWidgets('deleting an in-use profile asks and unassigns', (tester) async {
    final settings = await pump(tester, const LoadCellBankSection());
    await settings.saveLoadCell(
      LoadCellProfile(id: 'a', name: 'DUT', capacityKg: 50, sensitivityMvV: 1),
    );
    await settings.assignLoadCell(2, 'a');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ch 3'), findsOneWidget); // "in use" warning
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(settings.loadCellBank, isEmpty);
    expect(settings.channelLoadCellIds[2], isNull);
  });
}
