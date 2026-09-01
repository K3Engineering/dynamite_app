import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/screens/sessions_tab.dart';
import 'package:dynamite_app/services/live_session_writer.dart';
import 'package:dynamite_app/services/session_files_io.dart';
import 'package:dynamite_app/services/session_journal.dart';
import 'package:dynamite_app/services/session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channels = 4;
  const codec = SessionChunkCodec(channels);

  late Directory tmp;
  late IoSessionFilesBackend backend;
  late SessionStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sessions_tab_test');
    backend = IoSessionFilesBackend('${tmp.path}/sessions');
    SessionStore.instance = store = SessionStore.over(backend);
  });

  tearDown(() {
    SessionStore.instance = null;
    tmp.deleteSync(recursive: true);
  });

  SessionMeta meta(String name) => SessionMeta(
    name: name,
    sampleRate: 1000,
    channelCount: channels,
    channelLabels: const ['a', 'b', 'c', 'd'],
    tares: const [null, null, null, null],
    calibration: [
      for (var ch = 0; ch < channels; ch++)
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

  Future<void> seedSession(
    WidgetTester tester,
    String id,
    String name, {
    required bool notify,
  }) => tester.runAsync(() async {
    final data = codec.pack(2, (sample, channel) => sample + channel);
    final sink = await backend.createSession(
      id,
      encodeSessionMeta(meta(name)),
      data,
    );
    await sink.close();
    if (notify) {
      await store.touchFinal(id);
    } else {
      await backend.touchFinal(id);
    }
  });

  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(finder, findsOneWidget);
    await tester.pump();
  }

  testWidgets('shows a new session after the catalog becomes empty', (
    tester,
  ) async {
    const firstId = '2026-08-29T09-00-00-aaa1';
    const secondId = '2026-08-29T09-01-00-aaa2';
    await seedSession(tester, firstId, 'First session', notify: false);
    await tester.runAsync(store.refreshCatalog);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SessionsTab())),
    );
    await pumpUntil(tester, find.text('First session'));
    final originalState = tester.state(find.byType(SessionsTab));

    await tester.runAsync(() => store.deleteSession(firstId));
    await pumpUntil(tester, find.text('No recorded sessions yet'));
    expect(tester.state(find.byType(SessionsTab)), same(originalState));

    await seedSession(tester, secondId, 'Second session', notify: true);
    await pumpUntil(tester, find.text('Second session'));
    expect(tester.state(find.byType(SessionsTab)), same(originalState));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
