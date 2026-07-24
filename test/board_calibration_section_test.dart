import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/app_settings.dart';
import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/widgets/board_calibration_section.dart';

/// Widget tests for the board calibration view in the device settings
/// section, fed by the fixture document the demo and mock devices serve.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(DataHub, AppSettings)> pump(
    WidgetTester tester, {
    BoardCalibration? board,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final hub = DataHub();
    if (board != null) hub.updateBoardCalibration(board);
    final settings = AppSettings();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DataHub>.value(value: hub),
          ChangeNotifierProvider<AppSettings>.value(value: settings),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: BoardCalibrationSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (hub, settings);
  }

  testWidgets('shows factory status and per-channel summaries', (tester) async {
    await pump(tester, board: BoardCalibration.parse(demoBoardCalibrationDoc));

    expect(find.textContaining('Factory calibration'), findsOneWidget);
    expect(find.textContaining('2026-07-20'), findsWidgets);
    expect(
      find.textContaining('Factory excitation measurement'),
      findsOneWidget,
    );
    // Per-channel tiles with the fixture's offsets in their summaries.
    expect(find.text('Ch 1'), findsOneWidget);
    expect(find.textContaining('+845.2'), findsOneWidget);
    expect(find.textContaining('-231.5'), findsOneWidget);
    // ch0 carries a +30-count bow at +mid: 30/(6386310.2-845.2)*1e6 = +4.7 ppm.
    expect(find.textContaining('+4.7 ppm'), findsOneWidget);
  });

  testWidgets('expanding a channel reveals the 5-point table', (tester) async {
    final board = BoardCalibration.parse(demoBoardCalibrationDoc);
    await pump(tester, board: board);

    await tester.tap(find.text('Ch 1'));
    await tester.pumpAndSettle();

    expect(find.text('(t1, t5)'), findsOneWidget);
    expect(find.text('(t3, t3)'), findsOneWidget);
    // Setpoints formatted to 4 decimals, readings to 1.
    final ch0 = board.channels[0];
    for (int k = 0; k < kCalPointCount; k++) {
      expect(
        find.text(ch0.setpoints[k].toStringAsFixed(4)),
        findsOneWidget,
        reason: 'setpoint $k',
      );
      expect(
        find.text(ch0.readings![k].toStringAsFixed(1)),
        findsWidgets,
        reason: 'reading $k',
      );
    }
  });

  testWidgets('uncalibrated board shows the nominal fallback', (tester) async {
    await pump(tester); // fresh hub: BoardCalibration.nominal()

    expect(find.textContaining('nominal values in use'), findsOneWidget);
    expect(find.text('Nominal values (no factory data)'), findsNWidgets(4));
  });

  testWidgets('a DMM reading shows per-channel implied gain error', (
    tester,
  ) async {
    final board = BoardCalibration.parse(demoBoardCalibrationDoc);
    final (hub, settings) = await pump(tester, board: board);

    expect(find.textContaining('implied chain gain error'), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Your DMM excitation reading (mV)'),
      '4530.24',
    );
    await tester.pumpAndSettle();

    expect(settings.measuredExcitationMv, closeTo(4530.24, 1e-9));
    expect(find.textContaining('implied chain gain error'), findsNWidgets(4));
    // ch0 span vs the DMM: span/(countsPerMv * 4.53024) - 1.
    final err =
        (board.channels[0].spanCountsPerMvV /
                (countsPerMvAtCellOutput * 4.53024) -
            1) *
        100;
    final sign = err >= 0 ? '+' : '';
    expect(
      find.textContaining(
        'Ch 1: implied chain gain error $sign${err.toStringAsFixed(3)} %',
      ),
      findsOneWidget,
    );
  });

  testWidgets('clearing the DMM field removes the gain error rows', (
    tester,
  ) async {
    final (hub, settings) = await pump(
      tester,
      board: BoardCalibration.parse(demoBoardCalibrationDoc),
    );
    await settings.setMeasuredExcitationMv(4530.24);
    await tester.pump();

    final field = find.widgetWithText(
      TextFormField,
      'Your DMM excitation reading (mV)',
    );
    await tester.enterText(field, '');
    await tester.pumpAndSettle();

    expect(settings.measuredExcitationMv, isNull);
    expect(find.textContaining('implied chain gain error'), findsNothing);
  });
}
