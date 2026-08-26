import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/database.dart';
import 'package:dynamite_app/services/recording_controller.dart';
import 'package:dynamite_app/services/session_metadata.dart';
import 'package:dynamite_app/services/session_storage.dart';

/// [RecordingController] owns the session lifecycle start to finish, as an
/// explicit idle/recording/stopping machine: it latches the session's writer
/// on start (synchronously — no DB work happens until data exists), refuses
/// every operation whose state doesn't match, refuses to start while a tare
/// is averaging or no decodable data is flowing, and hands the session name
/// back on stop so the UI never touches storage.
///
/// startSession asserts the stream is live (the live tab only shows the
/// record button while streaming), so these tests hold the stream-liveness
/// port at a constant true rather than driving a mock connection.
void main() {
  (RecordingController, DataHub, ValueNotifier<bool>) wire() {
    final events = AppEvents();
    final hub = DataHub();
    final decoder = AdcPacketDecoder(hub);
    final streaming = ValueNotifier<bool>(true);
    final recording = RecordingController(
      dataHub: hub,
      streamingChanges: streaming,
      streamingNow: () => streaming.value,
      deviceMetadataSnapshot: () =>
          toSessionDeviceMetadata(name: null, info: null),
      onSessionBoundary: decoder.resetContinuity,
      persistence: const StaticSessionPersistence(),
      events: events,
    );
    // In production a packet counter anchor precedes any samples (packets
    // precede samples); tests must satisfy the same invariant.
    hub.notePacketCounter(0);
    addTearDown(recording.dispose);
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

  test('startSession refuses while a tare is averaging', () async {
    final (recording, hub, _) = wire();

    hub.requestTare();
    expect(hub.taring, isTrue);

    final result = start(recording);

    expect(result, isA<StartSessionTareInProgress>());
    expect(recording.sessionInProgress, isFalse);
  });

  test('startSession refuses when no decodable data is flowing', () async {
    final (recording, hub, _) = wire();
    // Age the stream past the feed-health freshness window with no packet
    // ever arriving: positively silent, not merely starting.
    hub.streamStartedAt = DateTime.now().subtract(const Duration(seconds: 5));

    final result = start(recording);

    expect(result, isA<StartSessionNoData>());
    expect(recording.sessionInProgress, isFalse);
  });

  test(
    'startSession refuses when only malformed packets are arriving',
    () async {
      final (recording, hub, _) = wire();
      hub.streamStartedAt = DateTime.now().subtract(const Duration(seconds: 5));
      hub.noteMalformedPacket(182);

      final result = start(recording);

      expect(result, isA<StartSessionNoData>());
      expect(recording.sessionInProgress, isFalse);
    },
  );

  test(
    'start latches the writer; stop finalizes it and returns its name',
    () async {
      AppDatabase.instance = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(AppDatabase.closeInstance);

      final (recording, hub, _) = wire();

      final startResult = recording.startSession(
        channelLabels: const ['Load Cell 1', 'Load Cell 2', 'Ch 3', 'Ch 4'],
        visibleChannels: const [true, true, false, false],
        displayUnit: DisplayUnit.kN,
      );
      expect(startResult, isA<StartSessionOk>());
      expect(recording.sessionInProgress, isTrue);
      // No data yet, so no row: the writer creates it on its first chunk
      // flush (no row without data).
      expect(await AppDatabase.instance.incompleteSessions(), isEmpty);

      // Record a few frames so the finalized session has data. The controller
      // streams hub slices to the writer via the samples-appended listener,
      // notified by commitBatch once per (simulated) packet.
      feedFrames(hub, 10);

      final stop = await recording.stopSession();
      expect(recording.sessionInProgress, isFalse);
      expect(stop.error, isNull);
      expect(stop.sessionId, isNotNull);

      // The saved row carries the auto-generated name, and stop hands it back
      // directly — the caller never re-queries the DB for it.
      final saved = await AppDatabase.instance.sessionById(stop.sessionId!);
      expect(saved, isNotNull);
      expect(saved!.isCompleted, isTrue);
      expect(saved.sampleCount, 10);
      expect(
        saved.name,
        matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')),
      );
      expect(stop.name, saved.name);
      expect(
        saved.channelLabels,
        '["Load Cell 1","Load Cell 2","Ch 3","Ch 4"]',
      );
      // The display unit is frozen at recording start (the CSV export's
      // default converted unit).
      expect(saved.displayUnit, 'kN');
      // The device identity block is frozen alongside (the CSV `device`
      // metadata). This harness's snapshot has no name/DIS read, so every
      // field is the null placeholder.
      expect(
        saved.deviceInfoJson,
        '{"name":null,"id":null,"model":null,"hardware_rev":null,'
        '"firmware":null,"manufacturer":null}',
      );
    },
  );

  test('a second start while recording is refused', () async {
    AppDatabase.instance = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(AppDatabase.closeInstance);

    final (recording, _, _) = wire();

    expect(start(recording), isA<StartSessionOk>());
    expect(start(recording), isA<StartSessionBusy>());
    expect(recording.sessionInProgress, isTrue);

    // No frames ever arrived, so no row ever existed: stopping finalizes
    // nothing (recorded nothing saves nothing).
    final stop = await recording.stopSession();
    expect(stop.error, isNull);
    expect(stop.sessionId, isNull);
    expect(await AppDatabase.instance.incompleteSessions(), isEmpty);
  });

  test('a start while finalization is in flight is refused', () async {
    AppDatabase.instance = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(AppDatabase.closeInstance);

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
    expect(stop.error, isNull);
    expect(recording.sessionInProgress, isFalse);
  });

  test(
    'stopSession folds a finalization failure into the returned error',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      AppDatabase.instance = db;
      // Don't closeInstance() in teardown: this test closes the db itself.
      addTearDown(() => AppDatabase.instance = null);

      final (recording, hub, _) = wire();

      expect(start(recording), isA<StartSessionOk>());
      feedFrames(hub, 1);

      // Open the connection, then close the DB out from under the session:
      // drift opens the underlying database lazily on the first statement,
      // so closing a never-spoken-to database would be a no-op and the write
      // below would succeed on a fresh (empty) connection. With a real
      // connection closed, the finalizing first-chunk flush fails — and
      // since that flush is also what creates the session row, no id was
      // ever latched. The failure must surface as the returned error —
      // stopSession also runs on unawaited auto-stop paths, so it must never
      // throw itself.
      await db.incompleteSessions();
      await db.close();

      final stop = await recording.stopSession();
      expect(recording.sessionInProgress, isFalse);
      expect(stop.sessionId, isNull);
      expect(stop.error, isNotNull);
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
