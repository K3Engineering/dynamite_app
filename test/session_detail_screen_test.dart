import 'dart:convert';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/screens/session_detail_screen.dart';
import 'package:dynamite_app/services/database.dart';
import 'package:dynamite_app/services/live_session_writer.dart';
import 'package:dynamite_app/services/session_queries.dart';
import 'package:dynamite_app/utils/format.dart';
import 'package:dynamite_app/widgets/empty_placeholder.dart';

/// Widget tests for the Session detail screen's data-integrity surfaces:
/// the empty state for a session with no chunks, the error state for one
/// whose chunk data has no verified prefix, and the damage banner for one
/// whose metadata columns failed strict parsing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppDatabase.instance = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(AppDatabase.closeInstance);

  testWidgets('a session with no chunks renders the empty placeholder', (
    tester,
  ) async {
    final sessionId = await AppDatabase.instance.createSession(
      name: 'Empty session',
      sampleRate: 1000,
      channelCount: 4,
      channelLabels: '[]',
      tares: '[]',
      calibrationJson: '[]',
      visibleChannels: '[]',
      displayUnit: 'kgf',
      deviceInfoJson: '{}',
      boardMetaJson: null,
      ssnOrigin: 0,
    );
    await AppDatabase.instance.completeSession(
      sessionId,
      sampleCount: 0,
      durationMs: 0,
    );
    final session = (await sessionSummaryById(sessionId))!;

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(
            value: AppSettings(prefs: prefs),
          ),
        ],
        child: MaterialApp(home: SessionDetailScreen(session: session)),
      ),
    );
    // Let the load future land; the initial spinner gives way to the
    // placeholder, after which nothing schedules frames.
    await tester.pumpAndSettle();

    expect(find.byType(EmptyPlaceholder), findsOneWidget);
    expect(find.text('No recorded data for this session'), findsOneWidget);
    expect(find.byIcon(Icons.insert_chart_outlined), findsOneWidget);

    // Unmount the screen ourselves and elapse a tick, so the zero-duration
    // timer drift schedules when the row stream's StreamBuilder unsubscribes
    // (StreamQueryStore.markAsClosed) fires now — not during the binding's
    // final teardown, where it would trip the pending-timer check (and stall
    // the instance close in tearDown). A bare pump() does NOT elapse the
    // fake clock, so give it a duration.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  /// A valid calibration column (nominal chain only — no factory readings),
  /// so tests can target one damaged column at a time.
  final validCalibrationJson = jsonEncode([
    for (int ch = 0; ch < 4; ch++)
      ChannelCalibration(
        board: ChannelBoardCalibration(
          nominals: const ChannelNominals(
            adcFsrV: 1.2,
            afeGain: 101,
            pgaGain: 1,
            excitationV: 4.53,
          ),
        ),
      ).toJson(),
  ]);

  /// Minimal row boilerplate for the integrity tests below.
  Future<int> makeRow({String tares = '[0,0,0,0]', String? calibrationJson}) =>
      AppDatabase.instance.createSession(
        name: 'Integrity session',
        sampleRate: 1000,
        channelCount: 4,
        channelLabels: '[]',
        tares: tares,
        calibrationJson: calibrationJson ?? validCalibrationJson,
        visibleChannels: '[]',
        displayUnit: 'kgf',
        deviceInfoJson: '{}',
        boardMetaJson: null,
        ssnOrigin: 0,
      );

  Future<void> pumpDetail(WidgetTester tester, int sessionId) async {
    final session = (await sessionSummaryById(sessionId))!;
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(
            value: AppSettings(prefs: prefs),
          ),
        ],
        child: MaterialApp(home: SessionDetailScreen(session: session)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('a session damaged from its first chunk renders the error '
      'placeholder and offers the salvage export', (tester) async {
    final sessionId = await makeRow();
    // Chunk 0 missing: no verifiable prefix — no honest view exists.
    const codec = SessionChunkCodec(4);
    await AppDatabase.instance.insertChunk(
      sessionId,
      1,
      codec.pack(1, (s, ch) => 42),
    );
    await AppDatabase.instance.completeSession(
      sessionId,
      sampleCount: 1,
      durationMs: 1,
    );

    await pumpDetail(tester, sessionId);

    expect(find.byType(EmptyPlaceholder), findsOneWidget);
    expect(find.text('Error loading session'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    // The salvage export is reachable from the menu even here — the only
    // export possible for this session.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text(salvageExportLabel), findsOneWidget);
    // Dismiss the menu without invoking (delivery is platform code).
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await unmount(tester);
  });

  testWidgets('a damaged tare column needs no banner: the gross floor is '
      'honest', (tester) async {
    final sessionId = await makeRow(tares: '[0,0,"bogus",0]');
    const codec = SessionChunkCodec(4);
    await AppDatabase.instance.insertChunk(
      sessionId,
      0,
      codec.pack(2, (s, ch) => s),
    );
    await AppDatabase.instance.completeSession(
      sessionId,
      sampleCount: 2,
      durationMs: 2,
    );

    await pumpDetail(tester, sessionId);

    // The floor (null = no offset) is a first-class state — the screen is
    // exactly what a never-tared healthy session shows.
    expect(find.text('Session data damaged'), findsNothing);
    expect(find.text('Tare offset'), findsOneWidget);
    expect(find.text('Samples'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a truncated session names the cut point and offers the '
      'salvage export', (tester) async {
    final sessionId = await makeRow();
    const codec = SessionChunkCodec(4);
    // Chunks say 1,000 samples; the metadata claim of 1,500 fails against
    // them — the honest extent truncates at sample 1,000 (= 1s @ 1 kHz).
    await AppDatabase.instance.insertChunk(
      sessionId,
      0,
      codec.pack(1000, (s, ch) => s),
    );
    await AppDatabase.instance.completeSession(
      sessionId,
      sampleCount: 1500,
      durationMs: 1500,
    );

    await pumpDetail(tester, sessionId);

    expect(find.text('Session data damaged'), findsOneWidget);
    expect(
      find.text(
        'Data truncated at sample 1,000 (≈ 1s of recording) — later storage '
        'failed integrity checks and is hidden. Available raw via menu → '
        '"$salvageExportLabel".',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Download CSV (verified data)'), findsOneWidget);
    expect(find.text(salvageExportLabel), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await unmount(tester);
  });
}
