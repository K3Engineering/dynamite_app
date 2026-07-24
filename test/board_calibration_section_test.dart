import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/widgets/board_calibration_section.dart';

/// Widget tests for the board calibration view in the device settings
/// section. The section renders the flash document owned by [RigState] —
/// and only while that document belongs to the device it was handed — so
/// the harness is a [RigState] fed the fixture document.
class _FakeTransport implements RigFlashTransport {
  @override
  String get connectedDeviceId => 'dev1';

  @override
  String get connectedDeviceName => 'Bench unit';

  @override
  Future<void> writeFlashDoc(String doc) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<RigState> pump(
    WidgetTester tester, {
    bool withFlash = true,
    String deviceId = 'dev1',
    String? flashDoc,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final rig = RigState(transport: _FakeTransport());
    if (withFlash) {
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        DeviceFlash.parse(flashDoc ?? demoBoardCalibrationDoc),
      );
    }
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider<RigState>.value(value: rig)],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BoardCalibrationSection(deviceId: deviceId),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return rig;
  }

  testWidgets('shows factory status and per-channel summaries', (tester) async {
    await pump(tester);

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
    await pump(tester);

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

  testWidgets('no flash doc: placeholder card, no values', (tester) async {
    await pump(tester, withFlash: false);

    expect(find.text('No calibration data from the device'), findsOneWidget);
    expect(find.textContaining('nominal values in use'), findsNothing);
    expect(find.text('Ch 1'), findsNothing);
  });

  testWidgets('another device\'s flash doc is refused', (tester) async {
    // The doc on file belongs to dev1, but the section was handed dev2.
    await pump(tester, deviceId: 'dev2');

    expect(find.text('No calibration data from the device'), findsOneWidget);
    expect(find.textContaining('Factory calibration'), findsNothing);
  });

  testWidgets('a DMM reading shows per-channel implied gain error', (
    tester,
  ) async {
    final rig = await pump(tester);

    expect(find.textContaining('implied chain gain error'), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Your DMM excitation reading (mV)'),
      '4530.24',
    );
    await tester.pumpAndSettle();

    expect(rig.measuredExcitationMv, closeTo(4530.24, 1e-9));
    expect(find.textContaining('implied chain gain error'), findsNWidgets(4));
    // ch0 span vs the DMM: span/(countsPerMv * 4.53024) - 1.
    final board = BoardCalibration.parse(demoBoardCalibrationDoc);
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
    final rig = await pump(tester);

    final field = find.widgetWithText(
      TextFormField,
      'Your DMM excitation reading (mV)',
    );
    await tester.enterText(field, '4530.24');
    await tester.pumpAndSettle();
    expect(rig.measuredExcitationMv, closeTo(4530.24, 1e-9));
    expect(find.textContaining('implied chain gain error'), findsNWidgets(4));

    await tester.enterText(field, '');
    await tester.pumpAndSettle();

    expect(rig.measuredExcitationMv, isNull);
    expect(find.textContaining('implied chain gain error'), findsNothing);
  });

  testWidgets('DMM gain error rows cover factory-calibrated channels only', (
    tester,
  ) async {
    // Only CH1 of this document has factory data: the cross-check has a
    // measured span to compare only there — a nominal channel would just
    // echo the nominal 4.53 V assumption back as a fake "gain error".
    const partialCalDoc = '''
K3CAL1
ch0.r=10000.8,10.0012,9.9991,10.0008,10.0003,9999.4
ch0.raw=6386310.2,3193480.0,845.2,-3191769.6,-6384619.8
END
''';
    await pump(tester, flashDoc: partialCalDoc);

    // The header reflects the single calibrated channel.
    expect(find.textContaining('1 of 4 channels'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Your DMM excitation reading (mV)'),
      '4530.24',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('implied chain gain error'), findsOneWidget);
    expect(
      find.textContaining('Ch 1: implied chain gain error'),
      findsOneWidget,
    );
  });
}
