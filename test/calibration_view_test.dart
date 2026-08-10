import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/widgets/cal_deviation_plot.dart';
import 'package:dynamite_app/widgets/calibration_view.dart';

/// Widget tests for the factory calibration view (inline host). The view
/// renders the flash document owned by [RigState] — and only while that
/// document belongs to the device it was handed — so the harness is a
/// [RigState] fed the fixture document, with the PGA readback the demo
/// device reports (1x on all channels).
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<RigState> pump(
    WidgetTester tester, {
    bool withFlash = true,
    String deviceId = 'dev1',
    String? flashDoc,
    List<double>? pgaGains = const [1, 1, 1, 1],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final rig = RigState(
      transport: _FakeTransport(),
      prefs: await SharedPreferences.getInstance(),
    );
    if (withFlash) {
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        DeviceFlash.parse(
          flashDoc ?? demoBoardCalibrationDoc,
          pgaGains: pgaGains,
        ),
      );
    }
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider<RigState>.value(value: rig)],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: CalibrationView(deviceId: deviceId)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return rig;
  }

  testWidgets('shows header, trust line, provenance and channel corrections',
      (tester) async {
    await pump(tester);

    expect(find.textContaining('Calibrated 2026-07-20'), findsOneWidget);
    expect(find.textContaining('±0.5% of reading'), findsOneWidget);
    // The provenance line from the new cal.* keys.
    expect(find.textContaining('calboard-fw 1.2.1'), findsOneWidget);
    expect(find.textContaining('board_calibration 1.0'), findsOneWidget);
    expect(find.textContaining('24.6/24.1 °C'), findsOneWidget);
    // Per-channel correction summaries in µV/V (ch0 fixture values:
    // +0.264 µV/V zero balance, +0.02% gain, ±0.009 µV/V linearity).
    expect(find.text('CH 1'), findsOneWidget);
    expect(find.textContaining('zero +0.264 µV/V'), findsOneWidget);
    expect(find.textContaining('±0.009 µV/V'), findsOneWidget);
  });

  testWidgets('expanding a channel reveals the plot and the 5-point table',
      (tester) async {
    final board = BoardCalibration.parse(
      demoBoardCalibrationDoc,
      pgaGains: const [1, 1, 1, 1],
    );
    await pump(tester);
    expect(find.byType(CalDeviationPlot), findsNothing);

    await tester.tap(find.text('CH 1'));
    await tester.pumpAndSettle();

    expect(find.byType(CalDeviationPlot), findsOneWidget);
    // The framing sentence and the relabeled diagnostic rows.
    expect(
      find.textContaining('Full 5-point correction is applied'),
      findsOneWidget,
    );
    expect(find.text('Zero balance'), findsOneWidget);
    expect(find.textContaining('+0.264 µV/V'), findsWidgets);
    expect(find.text('Gain vs nominal'), findsOneWidget);
    expect(find.textContaining('+0.02%'), findsWidgets);
    expect(find.text('Linearity'), findsOneWidget);
    // The table, with its per-point deviation column.
    expect(find.text('(t1, t5)'), findsOneWidget);
    expect(find.text('(t3, t3)'), findsOneWidget);
    expect(find.text('Deviation (µV/V)'), findsOneWidget);
    expect(find.text('+0.009'), findsOneWidget); // ch0 bow at +mid
    expect(find.text('-0.003'), findsOneWidget); // ...and the −mid sag
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
    expect(find.text('CH 1'), findsNothing);
  });

  testWidgets('another device\'s flash doc is refused', (tester) async {
    // The doc on file belongs to dev1, but the view was handed dev2.
    await pump(tester, deviceId: 'dev2');

    expect(find.text('No calibration data from the device'), findsOneWidget);
    expect(find.textContaining('Calibrated'), findsNothing);
  });

  testWidgets('the header counts the factory-calibrated channels', (
    tester,
  ) async {
    // Only CH1 of this document has factory data.
    const partialCalDoc = '''
K3CAL1
ch0.r=10000.8,10.0012,9.9991,10.0008,10.0003,9999.4
ch0.raw=6386310.2,3193480.0,845.2,-3191769.6,-6384619.8
END
''';
    await pump(tester, flashDoc: partialCalDoc);

    expect(find.textContaining('1 of 4 channels'), findsOneWidget);
  });

  testWidgets('a PGA config change since calibration warns', (tester) async {
    const staleDoc = '''
K3CAL1
cal.date=2026-07-20
adc_fsr=1.2,nominal
exc=4.53,nominal
afe_gain=101,nominal
cal.adc=32,32,32,32
END
''';
    await pump(tester, flashDoc: staleDoc);

    expect(
      find.textContaining('ADC gain configuration changed since calibration'),
      findsOneWidget,
    );
  });

  testWidgets('copy report puts the calibration on the clipboard', (
    tester,
  ) async {
    // The test binding has no clipboard; mock the platform channel and
    // capture what the button writes.
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pump(tester);

    await tester.ensureVisible(find.text('Copy report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy report'));
    await tester.pumpAndSettle();

    expect(
      find.text('Calibration report copied to clipboard'),
      findsOneWidget,
    );
    final board = BoardCalibration.parse(
      demoBoardCalibrationDoc,
      pgaGains: const [1, 1, 1, 1],
    );
    expect(copied, calibrationReport(board, 'dev1'));
  });

  group('calibrationReport', () {
    test('mirrors the screen content as plain text', () {
      final board = BoardCalibration.parse(
        demoBoardCalibrationDoc,
        pgaGains: const [1, 1, 1, 1],
      );
      final report = calibrationReport(board, 'dev1');

      expect(report, contains('Device: dev1'));
      expect(report, contains('Calibrated: 2026-07-20'));
      expect(report, contains('calboard-fw 1.2.1'));
      expect(report, contains('board_calibration 1.0'));
      expect(report, contains('±0.5% of reading'));
      expect(report, contains('1 µV/V = 500 ppm'));
      expect(report, contains('CH 1: zero balance +0.264 µV/V'));
      expect(report, contains('gain +0.02% vs nominal'));
      expect(report, contains('sensitivity'));
      expect(report, contains('(t1, t5)'));
    });

    test('an uncalibrated channel reports nominal, not a void', () {
      const partialCalDoc = '''
K3CAL1
ch0.r=10000.8,10.0012,9.9991,10.0008,10.0003,9999.4
ch0.raw=6386310.2,3193480.0,845.2,-3191769.6,-6384619.8
END
''';
      final report = calibrationReport(
        BoardCalibration.parse(partialCalDoc),
        'dev1',
      );
      expect(report, contains('CH 1: zero balance'));
      expect(report, contains('CH 4: nominal values (no factory data)'));
    });
  });
}
