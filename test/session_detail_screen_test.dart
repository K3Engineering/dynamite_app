import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/screens/session_detail_screen.dart';
import 'package:dynamite_app/services/live_session_writer.dart';
import 'package:dynamite_app/services/session_files_io.dart';
import 'package:dynamite_app/services/session_journal.dart';
import 'package:dynamite_app/services/session_queries.dart';
import 'package:dynamite_app/services/session_store.dart';
import 'package:dynamite_app/widgets/empty_placeholder.dart';

/// Widget tests for the Session detail screen: a healthy session renders
/// its stats; a session whose data decodes to no honest view renders the
/// error placeholder (which offers no salvage — the Sessions list's
/// damaged entry, not this screen, owns that surface).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channels = 4;
  const codec = SessionChunkCodec(channels);

  late Directory tmp;
  late IoSessionFilesBackend backend;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('detail_screen_test');
    backend = IoSessionFilesBackend('${tmp.path}/sessions');
    SessionStore.instance = SessionStore.over(backend);
  });
  tearDown(() {
    SessionStore.instance = null;
    tmp.deleteSync(recursive: true);
  });

  SessionMeta meta() => SessionMeta(
    name: 'Detail session',
    sampleRate: 1000,
    channelCount: channels,
    channelLabels: const ['a', 'b', 'c', 'd'],
    tares: const [null, null, null, null],
    calibration: [
      for (int ch = 0; ch < channels; ch++)
        ChannelCalibration(
          board: ChannelBoardCalibration(
            nominals: const ChannelNominals(
              adcFsrV: 1.2,
              afeGain: 101,
              pgaGain: 1,
              excitationV: 4.53,
            ),
          ),
        ),
    ],
    visibleChannels: const [true, true, true, true],
    displayUnit: 'kgf',
    deviceInfo: const {},
    boardMeta: null,
    recordedAt: '2026-07-29T14:05:32.000Z',
    ssnOrigin: 0,
  );

  Future<void> seedSession(String id, Uint8List data) async {
    final sink = await backend.createSession(
      id,
      encodeSessionMeta(meta()),
      data,
    );
    await sink.close();
    await backend.touchFinal(id);
  }

  Future<void> pumpDetail(WidgetTester tester, String sessionId) async {
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

  testWidgets('a healthy session renders its stats', (tester) async {
    const id = '2026-08-28T14-30-12-aaa0';
    await seedSession(id, codec.pack(2, (s, ch) => s));

    await pumpDetail(tester, id);

    expect(find.text('Detail session'), findsOneWidget);
    expect(find.text('Tare offset'), findsOneWidget);
    expect(find.text('Samples'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Download CSV'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await unmount(tester);
  });

  testWidgets('an undecodable session renders the error placeholder', (
    tester,
  ) async {
    const id = '2026-08-28T14-30-12-bbb0';
    final data = codec.pack(2, (s, ch) => s);
    // A gap at frame 0 is a shape the write path never produces (the
    // decoder suppresses gap injection at recording start).
    codec.fillGapSentinels(data, [(0, 1)]);
    await seedSession(id, data);

    await pumpDetail(tester, id);

    expect(find.byType(EmptyPlaceholder), findsOneWidget);
    expect(find.text('Error loading session'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    await unmount(tester);
  });
}
