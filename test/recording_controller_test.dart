import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/database.dart';
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

  (RecordingController, DataHub) wire() {
    final events = AppEvents();
    final hub = DataHub();
    final decoder = AdcPacketDecoder(hub);
    final recording = RecordingController(
      dataHub: hub,
      linkManager: _StreamingLink(events: events),
      decoder: decoder,
      events: events,
    );
    addTearDown(recording.dispose);
    return (recording, hub);
  }

  test('startSession refuses while a tare is averaging', () async {
    final (recording, hub) = wire();

    hub.requestTare();
    expect(hub.taring, isTrue);

    final result = await recording.startSession(
      channelLabels: const ['a', 'b', 'c', 'd'],
      visibleChannels: const [true, true, false, false],
    );

    expect(result, isA<StartSessionTareInProgress>());
    expect(recording.sessionInProgress, isFalse);
  });

  test(
    'start creates the session row; stop finalizes it and returns its name',
    () async {
      AppDatabase.instance = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(AppDatabase.closeInstance);

      final (recording, hub) = wire();

      final start = await recording.startSession(
        channelLabels: const ['Load Cell 1', 'Load Cell 2', 'Ch 3', 'Ch 4'],
        visibleChannels: const [true, true, false, false],
      );
      expect(start, isA<StartSessionOk>());
      expect(recording.sessionInProgress, isTrue);

      // Record a few frames so the finalized session has data. The controller
      // streams hub slices to the writer via the samples-appended listener,
      // notified by commitBatch once per (simulated) packet.
      const n = 10;
      final frame = Int32List(DataHub.numAdcChannels);
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
      expect(saved.name, matches(RegExp(r'^\d+/\d+ \d+:\d{2}:\d{2}$')));
      expect(stop.name, saved.name);
      expect(
        saved.channelLabels,
        '["Load Cell 1","Load Cell 2","Ch 3","Ch 4"]',
      );
    },
  );
}

/// A [BleLinkManager] that reports a streaming link, so
/// [RecordingController.startSession]'s streaming precondition holds without
/// driving a mock connection.
class _StreamingLink extends BleLinkManager {
  _StreamingLink({required super.events});

  @override
  bool get isStreaming => true;
}
