import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/device_flash.dart';
import 'package:dynamite_app/models/device_info.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/session_catalog.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/session_files_io.dart';
import 'package:dynamite_app/services/recording_controller.dart';
import 'package:dynamite_app/services/session_metadata.dart';
import 'package:dynamite_app/services/session_store.dart';
import 'package:dynamite_app/services/session_store_backend.dart';

/// [RecordingController] owns the session lifecycle start to finish, as an
/// explicit idle/recording/stopping machine: it latches the session's writer
/// on start (synchronously — no store work happens until data exists),
/// refuses every operation whose state doesn't match, refuses to start while
/// a tare is averaging or no decodable data is flowing, and hands the session
/// name back on stop so the UI never touches storage.
///
/// startSession asserts the stream is live (the live tab only shows the
/// record button while streaming), so these tests hold the stream-liveness
/// port at a constant true rather than driving a mock connection. The store
/// is the real dart:io backend pointed at a temp sessions root — the
/// lifecycle runs end-to-end through it.
void main() {
  const testIdentity = DeviceInfo(
    manufacturer: 'K3 Engineering',
    model: 'Dynamite Sampler Pro Mk1',
    serial: 'A4CF1208F51E',
    hardwareRev: 'v700P',
    firmwareRev: 'v700P|v1.2.3',
  );

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('recording_test');
    SessionStore.instance = SessionStore.over(
      IoSessionFilesBackend('${tmp.path}/sessions'),
    );
  });
  tearDown(() {
    SessionStore.instance = null;
    tmp.deleteSync(recursive: true);
  });

  (RecordingController, DataHub, ValueNotifier<bool>) wire({
    KvsSnapshot? deviceKvs,
    // Set false when the test disposes the controller itself (a second
    // dispose would trip ChangeNotifier's own assert instead of the one
    // under test).
    bool disposeOnTearDown = true,
  }) {
    final events = AppEvents();
    final hub = DataHub();
    final decoder = AdcPacketDecoder(hub);
    final streaming = ValueNotifier<bool>(true);
    final recording = RecordingController(
      dataHub: hub,
      streamingChanges: streaming,
      streamingNow: () => streaming.value,
      deviceMetadataSnapshot: () =>
          toSessionDeviceMetadata(name: null, info: testIdentity),
      deviceKvsSnapshot: () => deviceKvs,
      onSessionBoundary: decoder.resetContinuity,
      events: events,
    );
    // In production a packet counter anchor precedes any samples (packets
    // precede samples); tests must satisfy the same invariant.
    hub.notePacketCounter(0);
    if (disposeOnTearDown) addTearDown(recording.dispose);
    return (recording, hub, streaming);
  }

  StartSessionResult start(RecordingController recording) =>
      recording.startSession(
        channelLabels: const ['a', 'b', 'c', 'd'],
        visibleChannels: const [true, true, true, true],
        displayUnit: DisplayUnit.kgf,
      );

  void feedFrames(DataHub hub, int n) {
    final frame = Int32List(kAdcChannelCount);
    for (var i = 0; i < n; i++) {
      frame[0] = 1000 + i;
      hub.addSampleFrame(frame);
    }
    hub.commitBatch(0);
  }

  test('startSession refuses while a tare is averaging', () {
    final (recording, hub, _) = wire();

    hub.requestTare();
    expect(hub.taring, isTrue);

    final result = start(recording);

    expect(result, isA<StartSessionTareInProgress>());
    expect(recording.sessionInProgress, isFalse);
  });

  test('startSession refuses when no decodable data is flowing', () {
    final (recording, hub, _) = wire();
    // Age the stream past the feed-health freshness window with no packet
    // ever arriving: positively silent, not merely starting.
    hub.streamStartedAt = DateTime.now().subtract(const Duration(seconds: 5));

    final result = start(recording);

    expect(result, isA<StartSessionNoData>());
    expect(recording.sessionInProgress, isFalse);
  });

  test('startSession refuses when only malformed packets are arriving', () {
    final (recording, hub, _) = wire();
    hub.streamStartedAt = DateTime.now().subtract(const Duration(seconds: 5));
    hub.noteMalformedPacket(182);

    final result = start(recording);

    expect(result, isA<StartSessionNoData>());
    expect(recording.sessionInProgress, isFalse);
  });

  test(
    'start latches the writer; stop finalizes it and returns its name',
    () async {
      final (recording, hub, _) = wire();

      final startResult = recording.startSession(
        channelLabels: const ['Load Cell 1', 'Load Cell 2', 'Ch 3', 'Ch 4'],
        visibleChannels: const [true, true, false, false],
        displayUnit: DisplayUnit.kN,
      );
      expect(startResult, isA<StartSessionOk>());
      expect(recording.sessionInProgress, isTrue);
      // No data yet, so no directory: the writer creates it on its first
      // packet (no artifact without data).
      expect(await loadSessionCount(), 0);

      // Record a few frames so the finalized session has data. The controller
      // streams hub slices to the writer via the samples-appended listener,
      // notified by commitBatch once per (simulated) packet.
      feedFrames(hub, 10);

      final stop = await recording.stopSession();
      expect(recording.sessionInProgress, isFalse);
      expect(stop, isA<StopSessionSaved>());
      final savedRun = stop as StopSessionSaved;

      // The saved session carries the auto-generated name, and stop hands it
      // back directly — the caller never re-queries the store for it.
      final saved = _readyCatalog(
        SessionStore.instance,
      ).session(savedRun.sessionId)!;
      expect(
        saved.name,
        matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')),
      );
      expect(savedRun.name, saved.name);
      expect(saved.channelLabels, [
        'Load Cell 1',
        'Load Cell 2',
        'Ch 3',
        'Ch 4',
      ]);
      expect(saved.visibleChannels, [true, true, false, false]);
      // The display unit is frozen at recording start (the CSV export's
      // default converted unit).
      expect(saved.displayUnit, DisplayUnit.kN);
      // The device identity block is frozen alongside (the CSV `device`
      // metadata). This harness's snapshot has no name; the identity fields
      // are the harness's fixture.
      expect(saved.deviceInfo, {
        'name': null,
        'id': 'A4CF1208F51E',
        'model': 'Dynamite Sampler Pro Mk1',
        'hardware_rev': 'v700P',
        'firmware': 'v700P|v1.2.3',
        'manufacturer': 'K3 Engineering',
      });
      // Counts derive from the data, so the load is the truth.
      final loaded = await SessionStore.instance.loadSession(
        savedRun.sessionId,
      );
      expect(loaded.sampleCount, 10);
      expect(loaded.channels[0][3], 1003);
    },
  );

  test('the raw KVS snapshot freezes into the saved session', () async {
    final snapshot = KvsSnapshot(
      factory: const {'charging': 'enabled', 'adc_fsr': '1.2'},
      user: const {'lc0.cap': '200'},
    );
    final (recording, hub, _) = wire(deviceKvs: snapshot);

    expect(start(recording), isA<StartSessionOk>());
    feedFrames(hub, 3);
    final stop = await recording.stopSession();
    expect(stop, isA<StopSessionSaved>());

    final loaded = await SessionStore.instance.loadSession(
      (stop as StopSessionSaved).sessionId,
    );
    expect(loaded.deviceKvs!.factory, snapshot.factory);
    expect(loaded.deviceKvs!.user, snapshot.user);
  });

  test('a second start while recording is refused', () async {
    final (recording, _, _) = wire();

    expect(start(recording), isA<StartSessionOk>());
    expect(start(recording), isA<StartSessionBusy>());
    expect(recording.sessionInProgress, isTrue);

    // No frames ever arrived, so no directory ever existed: stopping
    // finalizes nothing (recorded nothing saves nothing).
    final stop = await recording.stopSession();
    expect(stop, isA<StopSessionNothingRecorded>());
    expect(await loadSessionCount(), 0);
  });

  test('a start while finalization is in flight is refused', () async {
    final (recording, hub, _) = wire();

    expect(start(recording), isA<StartSessionOk>());
    feedFrames(hub, 4);

    // The stop synchronously enters the stopping state before its
    // finalization await; a REC tap landing in that window must not
    // overlap a new session with the old one's finalization (the old
    // session's storage-error event would otherwise surface mid-recording).
    final stopping = recording.stopSession();
    final second = start(recording);

    expect(second, isA<StartSessionBusy>());
    final stop = await stopping;
    expect(stop, isA<StopSessionSaved>());
    expect(recording.sessionInProgress, isFalse);
  });

  test(
    'stopSession from idle (and after a completed stop) is refused',
    () async {
      final (recording, hub, _) = wire();

      // _Idle: nothing to stop.
      expect(await recording.stopSession(), isA<StopSessionRefused>());
      expect(recording.sessionInProgress, isFalse);

      // A full lifecycle lands back in _Idle, where stop is refused again.
      expect(start(recording), isA<StartSessionOk>());
      feedFrames(hub, 2);
      expect(await recording.stopSession(), isA<StopSessionSaved>());
      expect(await recording.stopSession(), isA<StopSessionRefused>());
    },
  );

  test('a second stop while finalization is in flight is refused', () async {
    // The sink's close parks on a latch, holding the _Stopping window open
    // deterministically: finalize has flushed everything and waits inside
    // closeSink.
    final held = _HoldCloseBackend(
      IoSessionFilesBackend('${tmp.path}/sessions'),
    );
    SessionStore.instance = SessionStore.over(held);
    final (recording, hub, _) = wire();

    expect(start(recording), isA<StartSessionOk>());
    feedFrames(hub, 4);

    final sink = await _firstSink(held);
    final stopping = recording.stopSession();
    await sink.closeRequested.future;
    expect(recording.sessionInProgress, isTrue);

    // Same guard as a mid-finalize REC tap: one lifecycle operation at a
    // time (the payload belongs to the in-flight stop).
    expect(await recording.stopSession(), isA<StopSessionRefused>());

    sink.releaseClose.complete();
    expect(await stopping, isA<StopSessionSaved>());
    expect(recording.sessionInProgress, isFalse);
  });

  test('a batch arriving mid-finalize is dropped, never appended to the '
      'closing session', () async {
    final held = _HoldCloseBackend(
      IoSessionFilesBackend('${tmp.path}/sessions'),
    );
    SessionStore.instance = SessionStore.over(held);
    final (recording, hub, _) = wire();

    expect(start(recording), isA<StartSessionOk>());
    feedFrames(hub, 4);

    final sink = await _firstSink(held);
    final stopping = recording.stopSession();
    await sink.closeRequested.future;
    final sealedBytes = sink.dataBytes;

    // The hub keeps delivering while the lifecycle is _Stopping: the
    // controller's append path is gated to _Recording, so this batch must
    // not grow the writer's totalSamplesRecorded — which the persisted
    // byte count mirrors exactly (finalize's ack-vs-expected check would
    // otherwise trip).
    feedFrames(hub, 3);
    await Future<void>.delayed(Duration.zero);
    expect(sink.dataBytes, sealedBytes);

    sink.releaseClose.complete();
    final stop = await stopping;
    expect(stop, isA<StopSessionSaved>());

    // The finalized session holds exactly the four pre-stop samples.
    final loaded = await SessionStore.instance.loadSession(
      (stop as StopSessionSaved).sessionId,
    );
    expect(loaded.sampleCount, 4);
  });

  test(
    'dispose while a session is in progress trips the debug assert, and does '
    'not detach the finalization path',
    () async {
      final (recording, hub, _) = wire(disposeOnTearDown: false);
      expect(start(recording), isA<StartSessionOk>());
      feedFrames(hub, 2);

      // Disposing here cannot finalize (dispose is synchronous and the
      // controller owns no shutdown future), so the invariant is enforced
      // instead of silently orphaning the writer mid-write.
      expect(recording.dispose, throwsA(isA<AssertionError>()));

      // Release is still driven by stopSession — the path the app uses. The
      // assert fired but the lifecycle was left intact, so the run finalizes
      // normally rather than being lost.
      expect(recording.sessionInProgress, isTrue);
      expect(await recording.stopSession(), isA<StopSessionSaved>());
    },
  );

  test('dispose from idle is the normal path and does not assert', () async {
    final (recording, hub, _) = wire(disposeOnTearDown: false);
    expect(
      recording.dispose,
      returnsNormally,
      reason: 'app-lifetime teardown disposes an idle controller',
    );

    // A completed lifecycle returns to idle, where dispose is legal again.
    final (second, secondHub, _) = wire(disposeOnTearDown: false);
    expect(start(second), isA<StartSessionOk>());
    feedFrames(secondHub, 2);
    expect(await second.stopSession(), isA<StopSessionSaved>());
    expect(second.dispose, returnsNormally);
    // The first controller's writer never saw data: nothing to finalize.
    expect(await recording.stopSession(), isA<StopSessionRefused>());
  });

  test(
    'stopSession folds a finalization failure into the returned error',
    () async {
      // Point the store at sessions root that cannot be created (a regular
      // file sits in its way): the writer's first-packet create fails, no
      // id is ever latched, and the failure must surface as the returned
      // error — stopSession also runs on unawaited auto-stop paths, so it
      // must never throw itself.
      final blocker = File('${tmp.path}/sessions');
      await blocker.create();
      SessionStore.instance = SessionStore.over(
        IoSessionFilesBackend(blocker.path),
      );

      final (recording, hub, _) = wire();

      expect(start(recording), isA<StartSessionOk>());
      feedFrames(hub, 1);

      final stop = await recording.stopSession();
      expect(recording.sessionInProgress, isFalse);
      expect(stop, isA<StopSessionFailed>());
      expect((stop as StopSessionFailed).sessionId, isNull);
    },
  );

  test(
    'a storage failure mid-recording auto-stops and surfaces as an event',
    () async {
      // Real backend, but every post-create append throws: the writer latches
      // the failure, and its error callback must auto-stop the recording
      // without waiting for another batch.
      SessionStore.instance = SessionStore.over(
        _FailAppendBackend(IoSessionFilesBackend('${tmp.path}/sessions')),
      );
      final events = AppEvents();
      final hub = DataHub();
      final decoder = AdcPacketDecoder(hub);
      final streaming = ValueNotifier<bool>(true);
      final recording = RecordingController(
        dataHub: hub,
        streamingChanges: streaming,
        streamingNow: () => streaming.value,
        deviceMetadataSnapshot: () =>
            toSessionDeviceMetadata(name: null, info: testIdentity),
        deviceKvsSnapshot: () => null,
        onSessionBoundary: decoder.resetContinuity,
        events: events,
      );
      hub.notePacketCounter(0);
      addTearDown(recording.dispose);
      final seen = <RecordingStorageError>[];
      final sub = events.stream
          .where((e) => e is RecordingStorageError)
          .cast<RecordingStorageError>()
          .listen(seen.add);
      addTearDown(sub.cancel);

      expect(start(recording), isA<StartSessionOk>());
      // Two batches and no more: the first creates the session intact, the
      // second's append throws asynchronously inside the write queue. No
      // further data arrives — if the stop still depended on discovering
      // the latched error at the next batch, sessionInProgress would stay
      // true here (the waits below are only a bound for the async ladder).
      feedFrames(hub, 10);
      feedFrames(hub, 10);
      for (var i = 0; i < 20 && recording.sessionInProgress; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(recording.sessionInProgress, isFalse);
      expect(seen, hasLength(1));

      // What the first packet wrote survives on disk, but the store cannot
      // vouch for the session — no completion marker, no "complete" listing:
      // it lists as interrupted, and its bytes load through the normal path.
      final listed = _readyCatalog(SessionStore.instance);
      expect(listed.sessions, hasLength(1));
      expect(listed.sessions.single.interrupted, isTrue);
      expect(listed.damaged, isEmpty);
      final loaded = await SessionStore.instance.loadSession(
        listed.sessions.single.id,
      );
      expect(loaded.channels.first.length, 10);
      expect(loaded.channels[0][3], 1003);
    },
  );

  group('autoSessionName', () {
    test('ISO Y-M-D with 24h zero-padded H:MM:SS', () {
      expect(
        RecordingController.autoSessionName(DateTime(2026, 7, 29, 14, 5, 32)),
        '2026-07-29 14:05:32',
      );
    });

    test('zero-pads every field (CSV filenames sort chronologically)', () {
      expect(
        RecordingController.autoSessionName(DateTime(2026, 1, 5, 9, 5, 3)),
        '2026-01-05 09:05:03',
      );
    });
  });
}

/// Number of finalized sessions the store lists (the old "row exists?"
/// assertions' file-store equivalent).
Future<int> loadSessionCount() async {
  final store = SessionStore.instance;
  await store.ensureCatalogLoaded();
  return _readyCatalog(store).sessions.length;
}

SessionCatalog _readyCatalog(SessionStore store) =>
    switch (store.catalog.value) {
      SessionCatalogReady(:final catalog) => catalog,
      final state => throw StateError('Expected ready catalog, got $state'),
    };

/// Wait for the writer's first-packet create to hand out the held sink (the
/// append rides the writer's async write queue; the loop is only a bound,
/// like the auto-stop wait above).
Future<_HoldCloseSink> _firstSink(_HoldCloseBackend held) async {
  for (var i = 0; i < 50 && held.lastSink == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final sink = held.lastSink;
  if (sink == null) throw StateError('the first append never created a sink');
  return sink;
}

/// An [IoSessionFilesBackend] whose session sinks count appended bytes and
/// park [SessionDataSink.close] on a test-released latch — holding
/// finalization's async window (the controller's _Stopping state) open
/// deterministically.
class _HoldCloseBackend implements SessionFilesBackend {
  _HoldCloseBackend(this._inner);

  final IoSessionFilesBackend _inner;

  /// The most recent sink handed out (non-null after the writer's first
  /// packet lands).
  _HoldCloseSink? lastSink;

  @override
  Future<SessionDataSink> createSession(
    String id,
    Uint8List metaBytes,
    Uint8List firstData,
  ) async {
    final sink = _HoldCloseSink(
      await _inner.createSession(id, metaBytes, firstData),
    );
    sink.dataBytes = firstData.length;
    return lastSink = sink;
  }

  @override
  Future<List<String>> listDirIds() => _inner.listDirIds();
  @override
  Future<Uint8List?> readJournal(String id) => _inner.readJournal(id);
  @override
  Future<Uint8List?> readData(String id) => _inner.readData(id);
  @override
  Future<int> dataByteLength(String id) => _inner.dataByteLength(id);
  @override
  Future<bool> isFinalized(String id) => _inner.isFinalized(id);
  @override
  Future<void> touchFinal(String id) => _inner.touchFinal(id);
  @override
  Future<void> truncateJournal(String id, int bytes) =>
      _inner.truncateJournal(id, bytes);
  @override
  Future<void> appendJournal(String id, Uint8List bytes) =>
      _inner.appendJournal(id, bytes);
  @override
  Future<void> delete(String id) => _inner.delete(id);
}

class _HoldCloseSink implements SessionDataSink {
  _HoldCloseSink(this._inner);

  final SessionDataSink _inner;

  @override
  String get id => _inner.id;

  /// Bytes persisted through this sink (the create's first data included):
  /// the observable twin of the writer's accepted-sample count.
  int dataBytes = 0;

  /// Completes when [close] is entered (finalize reached closeSink).
  final Completer<void> closeRequested = Completer<void>();

  /// Release the parked [close].
  final Completer<void> releaseClose = Completer<void>();

  @override
  Future<int> append(Uint8List bytes) async {
    final length = await _inner.append(bytes);
    dataBytes += bytes.length;
    return length;
  }

  @override
  Future<void> close() async {
    closeRequested.complete();
    await releaseClose.future;
    return _inner.close();
  }
}

/// An [IoSessionFilesBackend] whose data sinks throw on every append: the
/// create (journal + first write) succeeds, then storage "dies".
class _FailAppendBackend implements SessionFilesBackend {
  _FailAppendBackend(this._inner);

  final IoSessionFilesBackend _inner;

  @override
  Future<SessionDataSink> createSession(
    String id,
    Uint8List metaBytes,
    Uint8List firstData,
  ) async {
    final sink = await _inner.createSession(id, metaBytes, firstData);
    return _FailAppendSink(id, sink);
  }

  @override
  Future<List<String>> listDirIds() => _inner.listDirIds();
  @override
  Future<Uint8List?> readJournal(String id) => _inner.readJournal(id);
  @override
  Future<Uint8List?> readData(String id) => _inner.readData(id);
  @override
  Future<int> dataByteLength(String id) => _inner.dataByteLength(id);
  @override
  Future<bool> isFinalized(String id) => _inner.isFinalized(id);
  @override
  Future<void> touchFinal(String id) => _inner.touchFinal(id);
  @override
  Future<void> truncateJournal(String id, int bytes) =>
      _inner.truncateJournal(id, bytes);
  @override
  Future<void> appendJournal(String id, Uint8List bytes) =>
      _inner.appendJournal(id, bytes);
  @override
  Future<void> delete(String id) => _inner.delete(id);
}

class _FailAppendSink implements SessionDataSink {
  _FailAppendSink(this.id, this._inner);

  @override
  final String id;

  final SessionDataSink _inner;

  @override
  Future<int> append(Uint8List bytes) async =>
      throw StateError('disk is on fire');

  @override
  Future<void> close() => _inner.close();
}
