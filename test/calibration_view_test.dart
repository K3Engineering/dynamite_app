import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/screens/calibration_screen.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/report_export.dart';
import 'package:dynamite_app/services/rig_flash_transport.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/widgets/cal_deviation_plot.dart';
import 'package:dynamite_app/widgets/calibration_text.dart';
import 'package:dynamite_app/widgets/calibration_view.dart';

/// Widget tests for the factory calibration view (the board calibration
/// page's body). The view renders the board it's handed; the per-device
/// document gating lives in [RigState.boardCalibrationFor] — so the harness
/// is a [RigState] fed the fixture document (with the PGA readback the demo
/// device reports, 1x on all channels), and the view gets the board the
/// gate returns.
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

  Future<void> pump(
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
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CalibrationView(board: rig.boardCalibrationFor(deviceId)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows header, trust line, provenance and channel corrections', (
    tester,
  ) async {
    await pump(tester);

    expect(find.textContaining('Calibrated 2026-07-20'), findsOneWidget);
    expect(find.textContaining('±0.5% of reading'), findsOneWidget);
    // The correction statement is board-level: the summary card, once.
    expect(
      find.textContaining('The full 5-point correction is applied'),
      findsOneWidget,
    );
    // The provenance line from the new cal.* keys.
    expect(find.textContaining('calboard-fw 1.2.1'), findsOneWidget);
    expect(find.textContaining('board_calibration 1.0'), findsOneWidget);
    expect(find.textContaining('24.6/24.1 °C'), findsOneWidget);
    // Per-channel correction summaries in µV/V (ch0 fixture values:
    // +0.264 µV/V zero offset, +0.02% gain, ±0.009 µV/V linearity).
    expect(find.text('CH 1'), findsOneWidget);
    expect(find.textContaining('zero offset +0.264 µV/V'), findsOneWidget);
    expect(
      find.textContaining('end-point linearity ±0.009 µV/V'),
      findsOneWidget,
    );
  });

  testWidgets('a calibrated channel shows the plot and the 5-point table', (
    tester,
  ) async {
    // Only CH1 of this document has factory data, so exactly one card has
    // the plot and the table.
    const singleCalDoc = '''
K3CAL1
cal.date=2026-07-20
adc_fsr=1.2,nominal
exc=4.53,nominal
afe_gain=101,nominal
ch0.r=10000.8,10.0012,9.9991,10.0008,10.0003,9999.4
ch0.raw=6386310.2,3193480.0,845.2,-3191769.6,-6384619.8
END
''';
    final board = BoardCalibration.parse(
      singleCalDoc,
      pgaGains: const [1, 1, 1, 1],
    );
    await pump(tester, flashDoc: singleCalDoc);

    // The titled nonlinearity plot, with its convention caption.
    expect(find.byType(CalDeviationPlot), findsOneWidget);
    // 'Nonlinearity' appears twice: the plot section title and the table
    // column header.
    expect(find.text('Nonlinearity'), findsNWidgets(2));
    expect(find.textContaining('gain and offset removed'), findsOneWidget);
    expect(find.textContaining('0 by definition'), findsOneWidget);
    expect(find.text('Zero offset'), findsOneWidget);
    expect(find.textContaining('+0.264 µV/V'), findsWidgets);
    expect(find.text('Gain vs nominal'), findsOneWidget);
    expect(find.textContaining('+0.02%'), findsWidgets);
    expect(find.text('End-point linearity'), findsOneWidget);
    // The table: quantity header row and subdued units row.
    expect(find.text('(t1, t5)'), findsOneWidget);
    expect(find.text('(t3, t3)'), findsOneWidget);
    expect(find.text('Error'), findsOneWidget);
    expect(find.text('mV/V'), findsOneWidget);
    expect(find.text('counts'), findsOneWidget);
    expect(find.text('µV/V'), findsNWidgets(2));
    // The old measured-error presentation is gone.
    expect(find.text('Measured error'), findsNothing);
    // Error column: as-found, nothing pinned — every cell nonzero here.
    final ch0 = board.channels[0];
    String fmt(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(3)}';
    for (final v in ch0.measuredErrorsUvV!) {
      expect(find.text(fmt(v)), findsOneWidget, reason: 'error cell $v');
    }
    // Nonlinearity column: the end-point deviations.
    expect(find.text('+0.009'), findsOneWidget); // ch0 bow at +mid
    expect(find.text('-0.003'), findsOneWidget); // ...and the −mid sag
    // Setpoints formatted to 4 decimals, readings to 1.
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

  testWidgets('calibrated channel without board constants: no error figures', (
    tester,
  ) async {
    // ch0 has factory data, but the constants are unresolvable (no
    // afe_gain) — the measured error has no reference chain.
    const noConstantsDoc = '''
K3CAL1
cal.date=2026-07-20
adc_fsr=1.2,nominal
exc=4.53,nominal
ch0.r=10000.8,10.0012,9.9991,10.0008,10.0003,9999.4
ch0.raw=6386310.2,3193480.0,845.2,-3191769.6,-6384619.8
END
''';
    await pump(tester, flashDoc: noConstantsDoc);

    expect(find.text('Error'), findsNothing);
    // The end-point nonlinearity needs no nominal chain: the plot, its
    // caption, and the column all survive.
    expect(find.byType(CalDeviationPlot), findsOneWidget);
    expect(find.text('Nonlinearity'), findsNWidgets(2));
    expect(find.textContaining('0 by definition'), findsOneWidget);
    expect(find.text('+0.009'), findsOneWidget);
  });

  testWidgets('no flash doc: placeholder card, no values', (tester) async {
    await pump(tester, withFlash: false);

    expect(find.text('Could not read calibration data'), findsOneWidget);
    expect(find.textContaining('nominal values in use'), findsNothing);
    expect(find.text('CH 1'), findsNothing);
  });

  testWidgets('another device\'s flash doc is refused', (tester) async {
    // The doc on file belongs to dev1, but the view was handed dev2.
    await pump(tester, deviceId: 'dev2');

    expect(find.text('Could not read calibration data'), findsOneWidget);
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

  /// Pump the board calibration page (the view's host, carrying the export
  /// button row) instead of the bare view.
  Future<RigState> pumpScreen(
    WidgetTester tester, {
    bool withFlash = true,
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
          demoBoardCalibrationDoc,
          pgaGains: const [1, 1, 1, 1],
        ),
      );
    }
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider<RigState>.value(value: rig)],
        child: const MaterialApp(home: CalibrationScreen(deviceId: 'dev1')),
      ),
    );
    await tester.pumpAndSettle();
    return rig;
  }

  testWidgets('the copy button puts the report on the clipboard', (
    tester,
  ) async {
    // The test binding has no clipboard; mock the platform channel and
    // capture what the copy action writes.
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
    await pumpScreen(tester);

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(find.text('Calibration report copied to clipboard'), findsOneWidget);
    final board = BoardCalibration.parse(
      demoBoardCalibrationDoc,
      pgaGains: const [1, 1, 1, 1],
    );
    // The device label is the name the flash read carried, not the id.
    expect(copied, calibrationReport(board, 'Bench unit'));
  });

  testWidgets('the export row offers copy, download and share', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
  });

  testWidgets('page without a flash doc: placeholder, no export buttons', (
    tester,
  ) async {
    await pumpScreen(tester, withFlash: false);

    expect(find.text('Could not read calibration data'), findsOneWidget);
    // Nothing to export without a document.
    expect(find.byType(OutlinedButton), findsNothing);
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
      expect(report, contains('Correction: The full 5-point correction'));
      expect(report, contains('Definitions: Error = measured reading'));
      expect(report, contains('Uncertainty: ±0.5% of reading'));
      expect(report, contains('not a traceable calibration'));
      expect(report, contains('CH 1: zero offset +0.264 µV/V'));
      expect(report, contains('gain +0.02% vs nominal'));
      expect(report, contains('end-point linearity ±0.009 µV/V'));
      expect(report, contains('sensitivity'));
      expect(report, contains('(t1, t5)'));
      // Per-point lines carry both figures; the error column's zero row
      // is the offset through the nominal chain.
      final ch0 = board.channels[0];
      final e0 = ch0.measuredErrorsUvV![kCalIdxZero];
      expect(
        report,
        contains('error ${e0 > 0 ? '+' : ''}${e0.toStringAsFixed(3)} µV/V'),
      );
      expect(report, contains('nonlinearity +0.009 µV/V'));
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
      expect(report, contains('CH 1: zero offset'));
      expect(report, contains('CH 4: nominal values (no factory data)'));
    });

    test('the export file name carries the device label', () {
      expect(
        calibrationReportFileName('Bench unit'),
        'calibration_report_Bench unit.txt',
      );
      // Illegal filename characters are scrubbed per the shared rules.
      expect(
        calibrationReportFileName('rig: A/B'),
        'calibration_report_rig- A-B.txt',
      );
    });
  });

  group('boardCalibrationStatusLine', () {
    test('no document: the read failed or never landed', () {
      expect(
        boardCalibrationStatusLine(null),
        'Could not read calibration data',
      );
    });

    test('a document without factory data: missing calibration', () {
      const noCalDoc = '''
K3CAL1
cal.date=2026-07-20
END
''';
      expect(
        boardCalibrationStatusLine(BoardCalibration.parse(noCalDoc)),
        'Missing factory calibration',
      );
    });

    test('calibrated: the document\'s date and its age', () {
      final board = BoardCalibration.parse(
        demoBoardCalibrationDoc,
        pgaGains: const [1, 1, 1, 1],
      );
      expect(
        boardCalibrationStatusLine(board),
        startsWith('Calibrated 2026-07-20 ('),
      );
      expect(boardCalibrationStatusLine(board), endsWith('ago)'));
    });
  });
}
