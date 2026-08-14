import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/calibration.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/adc_protocol.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/database.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/mockble.dart';
import 'package:dynamite_app/services/recording_controller.dart';

/// [RecordingController] owns the session lifecycle start to finish: it
/// creates the session (via SessionStorage) on start, refuses to start while
/// a tare is averaging, and hands the session name back on stop so the UI
/// never touches storage.
///
/// startSession asserts the link is streaming (the live tab only shows the
/// record button while streaming), so these tests fake that one state rather
/// than driving a mock connection.
void main() {
  setUp(() {
    // Satisfy BleLinkManager's startup availability query without platform
    // channels (same harness as widget_test).
    UniversalBle.setInstance(MockBlePlatform.instance);
    MockBlePlatform.instance.dropEveryNPackets = 0;
  });

  (RecordingController, DataHub, _StreamingLink) wire() {
    final events = AppEvents();
    final hub = DataHub();
    final decoder = AdcPacketDecoder(hub);
    final link = _StreamingLink(events: events);
    final recording = RecordingController(
      dataHub: hub,
      linkManager: link,
      decoder: decoder,
      events: events,
    );
    addTearDown(recording.dispose);
    return (recording, hub, link);
  }

  test('startSession refuses while a tare is averaging', () async {
    final (recording, hub, _) = wire();

    hub.requestTare();
    expect(hub.taring, isTrue);

    final result = await recording.startSession(
      channelLabels: const ['a', 'b', 'c', 'd'],
      visibleChannels: const [true, true, false, false],
      displayUnit: DisplayUnit.kgf,
    );

    expect(result, isA<StartSessionTareInProgress>());
    expect(recording.sessionInProgress, isFalse);
  });

  test('startSession refuses when no decodable data is flowing', () async {
    final (recording, hub, _) = wire();
    // Age the stream past the feed-health freshness window with no packet
    // ever arriving: positively silent, not merely starting.
    hub.streamStartedAt = DateTime.now().subtract(const Duration(seconds: 5));

    final result = await recording.startSession(
      channelLabels: const ['a', 'b', 'c', 'd'],
      visibleChannels: const [true, true, false, false],
      displayUnit: DisplayUnit.kgf,
    );

    expect(result, isA<StartSessionNoData>());
    expect(recording.sessionInProgress, isFalse);
  });

  test('startSession refuses when only malformed packets are arriving', () async {
    final (recording, hub, _) = wire();
    hub.streamStartedAt = DateTime.now().subtract(const Duration(seconds: 5));
    hub.noteMalformedPacket(182);

    final result = await recording.startSession(
      channelLabels: const ['a', 'b', 'c', 'd'],
      visibleChannels: const [true, true, false, false],
      displayUnit: DisplayUnit.kgf,
    );

    expect(result, isA<StartSessionNoData>());
    expect(recording.sessionInProgress, isFalse);
  });

  test(
    'start creates the session row; stop finalizes it and returns its name',
    () async {
      AppDatabase.instance = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(AppDatabase.closeInstance);

      final (recording, hub, _) = wire();

      final start = await recording.startSession(
        channelLabels: const ['Load Cell 1', 'Load Cell 2', 'Ch 3', 'Ch 4'],
        visibleChannels: const [true, true, false, false],
        displayUnit: DisplayUnit.kN,
      );
      expect(start, isA<StartSessionOk>());
      expect(recording.sessionInProgress, isTrue);

      // Record a few frames so the finalized session has data. The controller
      // streams hub slices to the writer via the samples-appended listener,
      // notified by commitBatch once per (simulated) packet.
      const n = 10;
      final frame = Int32List(wireNumAdcChan);
      for (var i = 0; i < n; i++) {
        frame[0] = 1000 + i;
        hub.addSampleFrame(frame);
      }
      hub.commitBatch(0);

      final stop = await recording.stopSession();
      expect(recording.sessionInProgress, isFalse);
      expect(stop.error, isNull);
      expect(stop.sessionId, isNotNull);

      // The saved row carries the auto-generated name, and stop hands it back
      // directly — the caller never re-queries the DB for it.
      final saved = await AppDatabase.instance.sessionById(stop.sessionId!);
      expect(saved, isNotNull);
      expect(saved!.isCompleted, isTrue);
      expect(saved.sampleCount, n);
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
      // metadata). This harness's link has no name/DIS read, so every field
      // is the null placeholder.
      expect(
        saved.deviceInfoJson,
        '{"name":null,"id":null,"model":null,"firmware":null,'
        '"manufacturer":null}',
      );
    },
  );

  test(
    'a link drop during session creation refuses and discards the row',
    () async {
      AppDatabase.instance = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(AppDatabase.closeInstance);

      final (recording, _, link) = wire();

      // Flip the flag synchronously, before the event loop can resume the
      // creation future: this is the drop landing mid-insert. Without the
      // post-await link re-check, the writer would latch onto the dead link —
      // and a later reconnect would splice the new device's stream into it.
      final future = recording.startSession(
        channelLabels: const ['a', 'b', 'c', 'd'],
        visibleChannels: const [true, true, true, true],
        displayUnit: DisplayUnit.kgf,
      );
      link.streaming = false;
      final result = await future;

      expect(result, isA<StartSessionLinkLost>());
      expect(recording.sessionInProgress, isFalse);
      // The orphan row was discarded, not left behind for crash recovery.
      expect(await AppDatabase.instance.incompleteSessions(), isEmpty);
    },
  );

  test(
    'stopSession folds a finalization failure into the returned error',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      AppDatabase.instance = db;
      // Don't closeInstance() in teardown: this test closes the db itself.
      addTearDown(() => AppDatabase.instance = null);

      final (recording, hub, _) = wire();

      final start = await recording.startSession(
        channelLabels: const ['a', 'b', 'c', 'd'],
        visibleChannels: const [true, true, true, true],
        displayUnit: DisplayUnit.kgf,
      );
      expect(start, isA<StartSessionOk>());

      final frame = Int32List(wireNumAdcChan);
      hub.addSampleFrame(frame);
      hub.commitBatch(0);

      // Close the DB out from under the session: the finalizing completion
      // write then throws. The failure must surface as the returned error —
      // stopSession also runs on unawaited auto-stop paths, so it must never
      // throw itself.
      await db.close();

      final stop = await recording.stopSession();
      expect(recording.sessionInProgress, isFalse);
      expect(stop.sessionId, isNotNull);
      expect(stop.error, isNotNull);
    },
  );

  test('a link drop forgets the dead device\'s board calibration', () {
    final (_, hub, link) = wire();
    hub.updateBoardCalibration(
      BoardCalibration.parse(
        demoBoardCalibrationDoc,
        pgaGains: const [32, 32, 32, 32],
      ),
    );
    // Sync the controller's transition tracker (idle -> streaming); the
    // production controller pre-exists the first connection, so it sees
    // every edge.
    link.setStreaming(true);
    expect(hub.boardDataStatus, BoardDataStatus.ok);

    link.setStreaming(false);
    expect(hub.boardCalibration, isNull);
    expect(hub.boardDataStatus, BoardDataStatus.unreadable);
  });

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

/// A [BleLinkManager] whose streaming state is a plain settable flag, so
/// [RecordingController.startSession]'s streaming precondition holds without
/// driving a mock connection (and can be flipped mid-test to simulate a drop).
class _StreamingLink extends BleLinkManager {
  _StreamingLink({required super.events});

  bool streaming = true;

  /// Flip [streaming] and notify, so the controller's transition detection
  /// sees the edge.
  void setStreaming(bool value) {
    streaming = value;
    notifyListeners();
  }

  @override
  bool get isStreaming => streaming;
}
