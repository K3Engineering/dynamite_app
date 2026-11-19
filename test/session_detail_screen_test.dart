import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/session_catalog.dart';
import 'package:dynamite_app/models/session_summary.dart';
import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/services/session_data.dart';
import 'package:dynamite_app/screens/session_detail_screen.dart';
import 'package:dynamite_app/services/live_session_writer.dart';
import 'package:dynamite_app/services/session_files_io.dart';
import 'package:dynamite_app/services/session_journal.dart';
import 'package:dynamite_app/services/session_store.dart';
import 'package:dynamite_app/services/session_store_backend.dart';
import 'package:dynamite_app/widgets/empty_placeholder.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

import 'helpers/session_data_fixture.dart';

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
        const ChannelCalibration(
          board: NominalChannelBoard(
            ChannelNominals(
              adcFsrV: 1.2,
              afeGain: 101,
              pgaGain: 1,
              excitationV: 4.53,
            ),
          ),
        ),
    ],
    visibleChannels: const [true, true, true, true],
    displayUnit: .kgf,
    deviceInfo: const {},
    recordedAt: '2026-07-29T14:05:32.000Z',
    ssnOrigin: 0,
  );

  SessionSummary summary(String id) {
    final m = meta();
    return SessionSummary(
      id: id,
      name: m.name,
      notes: '',
      createdAt: DateTime.utc(2026, 8, 28, 14, 30, 12),
      durationMs: 2,
      channelCount: m.channelCount,
      sampleRate: m.sampleRate,
      displayUnit: m.displayUnit,
      deviceInfo: m.deviceInfo,
      recordedAt: m.recordedAt,
      channelLabels: m.channelLabels,
      visibleChannels: m.visibleChannels,
      interrupted: false,
    );
  }

  // Everything store-side is real dart:io, which the fake-async
  // testWidgets event loop starves; runAsync hands it the real loop.
  Future<void> seedSession(WidgetTester tester, String id, Uint8List data) =>
      tester.runAsync(() async {
        final sink = await backend.createSession(
          id,
          encodeSessionMeta(meta()),
          data,
        );
        await sink.close();
        await backend.touchFinal(id);
      });

  Future<void> pumpDetail(WidgetTester tester, String sessionId) async {
    await tester.runAsync(SessionStore.instance.refreshCatalog);
    final session = switch (SessionStore.instance.catalog.value) {
      SessionCatalogReady(:final catalog) => catalog.session(sessionId)!,
      final state => throw StateError('Expected ready catalog, got $state'),
    };
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
    // The screen's own load is real IO too, kicked off in initState where
    // runAsync can't wrap it; hand it real ticks until the spinner clears
    // (single-shot waits starve it: the load is several file round trips).
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('a healthy session renders its stats', (tester) async {
    const id = '2026-08-28T14-30-12-aaa0';
    await seedSession(tester, id, codec.pack(2, (s, ch) => s));

    await pumpDetail(tester, id);

    expect(find.text('Detail session'), findsOneWidget);
    expect(find.text('Tare offset'), findsOneWidget);
    expect(find.text('Samples'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    final downloadItem = find.ancestor(
      of: find.text('Download CSV'),
      matching: find.byType(PopupMenuItem<String>),
    );
    expect(downloadItem, findsOneWidget);
    expect(tester.widget<PopupMenuItem<String>>(downloadItem).enabled, isTrue);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await unmount(tester);
  });

  testWidgets('empty SessionData renders an empty graph', (tester) async {
    final data = sessionDataFixture(
      channels: [for (var ch = 0; ch < channels; ch++) Int32List(0)],
      sampleRate: 1000,
      calibrations: meta().calibration,
      tares: meta().tares,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GraphWorkspace(
          data: data,
          ctrl: GraphController(isLiveSource: false),
          unit: .mVv,
          activeChannels: const [0, 1, 2, 3],
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(GraphWorkspace), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('swapping static SessionData resets viewport and tile caches', (
    tester,
  ) async {
    SessionData sessionOf(int count, int rawValue) => sessionDataFixture(
      channels: [
        for (var ch = 0; ch < channels; ch++)
          Int32List(count)..fillRange(0, count, rawValue),
      ],
      sampleRate: 1000,
      calibrations: meta().calibration,
      tares: meta().tares,
    );

    final ctrl = GraphController(isLiveSource: false);
    final longSession = sessionOf(5000, 10000);
    final shortSession = sessionOf(100, 500);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 300,
          child: GraphWorkspace(
            data: longSession,
            ctrl: ctrl,
            unit: .raw,
            activeChannels: const [0],
            showDerivative: true,
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    ctrl.applyWindow(2000, 1000, longSession.totalSamples, 0);
    await tester.pump();

    // Swap in a shorter static session (still generation 0): both the parked
    // window [2000, 3000) and the [0, 5000) tile/reduction caches must clear.
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 300,
          child: GraphWorkspace(
            data: shortSession,
            ctrl: ctrl,
            unit: .raw,
            activeChannels: const [0],
            showDerivative: true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(ctrl.effectiveRange(shortSession.totalSamples, 0), (0, 100));

    await unmount(tester);
  });

  testWidgets(
    'a failed catalog without a data builder handles the load error',
    (tester) async {
      final backend = Completer<SessionFilesBackend>();
      final failedStore = SessionStore.overFuture(backend.future);
      SessionStore.instance = failedStore;
      final catalogLoad = failedStore.ensureCatalogLoaded();
      backend.completeError(StateError('backend unavailable'));
      await tester.runAsync(() => expectLater(catalogLoad, throwsStateError));
      expect(failedStore.catalog.value, isA<SessionCatalogFailed>());

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppSettings>.value(
              value: AppSettings(prefs: prefs),
            ),
          ],
          child: MaterialApp(
            home: SessionDetailScreen(
              session: summary('2026-08-28T14-30-12-fail'),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();

      expect(find.text('Error loading sessions'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  testWidgets('a recovered catalog starts a fresh session load', (
    tester,
  ) async {
    const id = '2026-08-28T14-30-12-ccc0';
    await seedSession(tester, id, codec.pack(2, (s, ch) => s));
    final recoveringBackend = _FailFirstListingBackend(backend);
    final recoveringStore = SessionStore.over(recoveringBackend);
    SessionStore.instance = recoveringStore;

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(
            value: AppSettings(prefs: prefs),
          ),
        ],
        child: MaterialApp(home: SessionDetailScreen(session: summary(id))),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(find.text('Error loading sessions'), findsNWidgets(2));

    recoveringBackend.failListings = false;
    await tester.runAsync(recoveringStore.refreshCatalog);
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Error loading session'), findsNothing);
    expect(find.text('Detail session'), findsOneWidget);
    expect(find.text('Samples'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    await seedSession(tester, id, data);

    await pumpDetail(tester, id);

    expect(find.byType(EmptyPlaceholder), findsOneWidget);
    expect(find.text('Error loading session'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    final downloadItem = find.ancestor(
      of: find.text('Download CSV'),
      matching: find.byType(PopupMenuItem<String>),
    );
    expect(tester.widget<PopupMenuItem<String>>(downloadItem).enabled, isFalse);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await unmount(tester);
  });
}

class _FailFirstListingBackend implements SessionFilesBackend {
  new(this.inner);

  final IoSessionFilesBackend inner;
  bool failListings = true;

  @override
  Future<List<String>> listDirIds() {
    if (failListings) throw StateError('listing unavailable');
    return inner.listDirIds();
  }

  @override
  Future<SessionDataSink> createSession(
    String id,
    Uint8List metaBytes,
    Uint8List firstData,
  ) => inner.createSession(id, metaBytes, firstData);

  @override
  Future<Uint8List?> readJournal(String id) => inner.readJournal(id);

  @override
  Future<Uint8List?> readData(String id) => inner.readData(id);

  @override
  Future<int> dataByteLength(String id) => inner.dataByteLength(id);

  @override
  Future<bool> isFinalized(String id) => inner.isFinalized(id);

  @override
  Future<void> touchFinal(String id) => inner.touchFinal(id);

  @override
  Future<void> truncateJournal(String id, int bytes) =>
      inner.truncateJournal(id, bytes);

  @override
  Future<void> appendJournal(String id, Uint8List bytes) =>
      inner.appendJournal(id, bytes);

  @override
  Future<void> delete(String id) => inner.delete(id);
}
