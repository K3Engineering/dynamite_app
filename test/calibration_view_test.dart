import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/screens/calibration_screen.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/report_export.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/widgets/cal_deviation_plot.dart';
import 'package:dynamite_app/widgets/calibration_text.dart';
import 'helpers/flash_docs.dart';
import 'package:dynamite_app/widgets/calibration_view.dart';

/// Widget tests for the factory calibration view (the board calibration
/// page's body). The view renders the board it's handed, so the harness
/// is a [RigState] fed the fixture document (with the PGA readback the
/// demo device reports, 1x on all channels), and the view gets
/// [RigState.boardCalibration]. No save is exercised, so no backend.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(
    WidgetTester tester, {
    bool withFlash = true,
    String? flashDoc,
    List<double> pgaGains = const [1, 1, 1, 1],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final rig = RigState(
      backend: () => null,
      connectedDeviceName: () => 'Bench unit',
      prefs: await SharedPreferences.getInstance(),
      events: AppEvents(),
    );
    if (withFlash) {
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        flashFromDoc(flashDoc ?? demoBoardCalibrationDoc, pgaGains: pgaGains),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CalibrationView(board: rig.boardCalibration),
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
    expect(find.text('CH 0'), findsOneWidget);
    expect(find.textContaining('zero offset +0.264 µV/V'), findsOneWidget);
    expect(
      find.textContaining('end-point linearity ±0.009 µV/V'),
      findsOneWidget,
    );
  });

  testWidgets('calibrated channels show the plot and the 5-point table', (
    tester,
  ) async {
    // The fixture document calibrates all four channels, so every card
    // carries the plot and the table (calibration is board-uniform — see
    // BoardCalibration.fromKv).
    final board =
        boardFromDoc(demoBoardCalibrationDoc, pgaGains: const [1, 1, 1, 1])
            as ProvisionedBoardCalibration;
    await pump(tester);

    // The titled nonlinearity plot, with its convention caption.
    expect(find.byType(CalDeviationPlot), findsNWidgets(4));
    // 'Nonlinearity' appears twice per card: the plot section title and the
    // table column header.
    expect(find.text('Nonlinearity'), findsNWidgets(8));
    expect(find.textContaining('gain and offset removed'), findsNWidgets(4));
    expect(find.textContaining('0 by definition'), findsNWidgets(4));
    expect(find.text('Zero offset'), findsNWidgets(4));
    expect(find.textContaining('+0.264 µV/V'), findsWidgets);
    expect(find.text('Gain vs nominal'), findsNWidgets(4));
    expect(find.textContaining('+0.02%'), findsWidgets);
    expect(find.text('End-point linearity'), findsNWidgets(4));
    // The table: quantity header row and subdued units row.
    expect(find.text('(t1, t5)'), findsNWidgets(4));
    expect(find.text('(t3, t3)'), findsNWidgets(4));
    expect(find.text('Error'), findsNWidgets(4));
    expect(find.text('mV/V'), findsNWidgets(4));
    expect(find.text('counts'), findsNWidgets(4));
    expect(find.text('µV/V'), findsNWidgets(8));
    // The old measured-error presentation is gone.
    expect(find.text('Measured error'), findsNothing);
    // Error column: as-found, nothing pinned — ch0's cells all appear.
    final ch0 = board.channels[0] as CalibratedChannelBoard;
    String fmt(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(3)}';
    for (final v in ch0.measuredErrorsUvV) {
      expect(find.text(fmt(v)), findsWidgets, reason: 'error cell $v');
    }
    // Nonlinearity column: the end-point deviations.
    expect(find.text('+0.009'), findsWidgets); // ch0 bow at +mid
    expect(find.text('-0.003'), findsWidgets); // ...and the −mid sag
    // Setpoints formatted to 4 decimals, readings to 1.
    for (int k = 0; k < kCalPointCount; k++) {
      expect(
        find.text(ch0.setpoints[k].toStringAsFixed(4)),
        findsWidgets,
        reason: 'setpoint $k',
      );
      expect(
        find.text(ch0.readings[k].toStringAsFixed(1)),
        findsWidgets,
        reason: 'reading $k',
      );
    }
  });

  testWidgets('no flash doc: disconnected card, no values', (tester) async {
    await pump(tester, withFlash: false);

    expect(find.text('Device disconnected'), findsOneWidget);
    expect(find.textContaining('nominal values in use'), findsNothing);
    expect(find.text('CH 0'), findsNothing);
  });

  testWidgets('an unprovisioned unit shows the raw-only card', (tester) async {
    // A unit with slots but no board data: a legal dev-board state, rendered
    // as one card — there is nothing per-channel to show.
    await pump(tester, flashDoc: 'lc0.cap=100\nlc0.sens=2\n');

    expect(find.text('No board data — unit not provisioned'), findsOneWidget);
    expect(find.text('raw counts only.'), findsOneWidget);
    expect(find.byType(CalDeviationPlot), findsNothing);
  });

  testWidgets('an invalid board shows the reason', (tester) async {
    // Flash held board data the app refused to adopt: the card names the
    // parser's reason (the device itself streams raw counts).
    await pump(tester, flashDoc: 'adc_fsr=1.2\nexc=soon\nafe_gain=101\n');

    expect(
      find.text('Calibration data unreadable — contact support'),
      findsOneWidget,
    );
    expect(find.textContaining('bad exc'), findsOneWidget);
    expect(find.byType(CalDeviationPlot), findsNothing);
  });

  testWidgets('a PGA config change since calibration warns', (tester) async {
    const staleDoc = '''
K3CAL1
cal.date=2026-07-20
adc_fsr=1.2,nominal
exc=4.53,nominal
afe_gain=101,nominal
cal.adc=32,32,32,32
ch0.r=10000,10,10,10,10,10000
ch0.raw=6000000,3000000,0,-3000000,-6000000
ch1.r=10000,10,10,10,10,10000
ch1.raw=6000000,3000000,0,-3000000,-6000000
ch2.r=10000,10,10,10,10,10000
ch2.raw=6000000,3000000,0,-3000000,-6000000
ch3.r=10000,10,10,10,10,10000
ch3.raw=6000000,3000000,0,-3000000,-6000000
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
      backend: () => null,
      connectedDeviceName: () => 'Bench unit',
      prefs: await SharedPreferences.getInstance(),
      events: AppEvents(),
    );
    if (withFlash) {
      rig.onFlashRead(
        'dev1',
        'Bench unit',
        flashFromDoc(demoBoardCalibrationDoc, pgaGains: const [1, 1, 1, 1]),
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
    final board =
        boardFromDoc(demoBoardCalibrationDoc, pgaGains: const [1, 1, 1, 1])
            as ProvisionedBoardCalibration;
    // The device label is the name the flash read carried, not the id.
    expect(copied, calibrationReport(board, 'Bench unit'));
  });

  testWidgets('the export row offers copy, download and share', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
  });

  testWidgets(
    'page without a flash doc: disconnected card, no export buttons',
    (tester) async {
      await pumpScreen(tester, withFlash: false);

      expect(find.text('Device disconnected'), findsOneWidget);
      // Nothing to export without a document.
      expect(find.byType(OutlinedButton), findsNothing);
    },
  );

  group('calibrationReport', () {
    test('mirrors the screen content as plain text', () {
      final board =
          boardFromDoc(demoBoardCalibrationDoc, pgaGains: const [1, 1, 1, 1])
              as ProvisionedBoardCalibration;
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
      expect(report, contains('CH 0: zero offset +0.264 µV/V'));
      expect(report, contains('gain +0.02% vs nominal'));
      expect(report, contains('end-point linearity ±0.009 µV/V'));
      expect(report, contains('sensitivity'));
      expect(report, contains('(t1, t5)'));
      // Per-point lines carry both figures; the error column's zero row
      // is the offset through the nominal chain.
      final ch0 = board.channels[0] as CalibratedChannelBoard;
      final e0 = ch0.measuredErrorsUvV[kCalIdxZero];
      expect(
        report,
        contains('error ${e0 > 0 ? '+' : ''}${e0.toStringAsFixed(3)} µV/V'),
      );
      expect(report, contains('nonlinearity +0.009 µV/V'));
    });

    test('an uncalibrated board reports nominal, not a void', () {
      const nominalDoc = '''
K3CAL1
adc_fsr=1.2,nominal
exc=4.53,nominal
afe_gain=101,nominal
END
''';
      final report = calibrationReport(
        boardFromDoc(nominalDoc, pgaGains: const [1, 1, 1, 1])
            as ProvisionedBoardCalibration,
        'dev1',
      );
      expect(report, contains('CH 0: nominal values (no calibration)'));
      expect(report, contains('CH 3: nominal values (no calibration)'));
      // The trust line matches the board, mirroring the screen.
      expect(report, contains('nominal chain in use'));
      expect(report, isNot(contains('Correction:')));
      expect(report, isNot(contains('WARNING')));
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

    test('board constants but no calibration data', () {
      const noCalDoc = '''
K3CAL1
adc_fsr=1.2,nominal
exc=4.53,nominal
afe_gain=101,nominal
END
''';
      expect(
        boardCalibrationStatusLine(
          boardFromDoc(noCalDoc, pgaGains: const [1, 1, 1, 1]),
        ),
        'Not calibrated — nominal values in use',
      );
    });

    test('an unprovisioned unit: raw counts only', () {
      expect(
        boardCalibrationStatusLine(const UnprovisionedBoardCalibration()),
        'Not provisioned — raw counts only',
      );
    });

    test('calibrated: the document\'s date and its age', () {
      final board =
          boardFromDoc(demoBoardCalibrationDoc, pgaGains: const [1, 1, 1, 1])
              as ProvisionedBoardCalibration;
      expect(
        boardCalibrationStatusLine(board),
        startsWith('Calibrated 2026-07-20 ('),
      );
      expect(boardCalibrationStatusLine(board), endsWith('ago)'));
    });
  });
}
