import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/demo_calibration.dart';
import 'package:dynamite_app/services/mockble.dart';
import 'package:dynamite_app/services/stream_reset_coordinator.dart';

/// The hub must start fresh on every new device stream: connecting (even to
/// the same device) clears the previous stream's ring buffer, peaks and gaps,
/// and restarts packet-continuity tracking so the new stream's first packet
/// isn't diffed against the old stream's counter. A dropped link additionally
/// forgets the dead device's board calibration.
///
/// Same mock-BLE + fakeAsync harness as mockble_test.dart, with a
/// [StreamResetCoordinator] added — its link observation performs the resets.
void main() {
  // The mock device that advertises the ADC service (see _generateServices).
  const deviceId = '2';

  (DataHub, BleLinkManager, VoidCallback) wire({required FakeAsync async}) {
    UniversalBle.setInstance(MockBlePlatform.instance);
    final events = AppEvents();
    final hub = DataHub();
    final decoder = AdcPacketDecoder(hub);
    final link = BleLinkManager(events: events)
      ..onAdcData = decoder.onDataPacket
      ..onCalibrationData = decoder.onCalibrationPacket;
    final reset = StreamResetCoordinator(
      hub: hub,
      streamingChanges: link,
      streamingNow: () => link.isStreaming,
    );

    return (
      hub,
      link,
      () {
        reset.dispose();
        // Best-effort disconnect so the mock's timers are cancelled and the
        // singleton is left idle for the next test.
        unawaited(link.disconnectSelectedDevice());
        async.elapse(const Duration(seconds: 4));
      },
    );
  }

  test('reconnecting resets the hub (no splice, no spurious gap)', () {
    fakeAsync((async) {
      MockBlePlatform.instance.dropEveryNPackets = 0;
      final (hub, link, teardown) = wire(async: async);

      unawaited(link.connectToDevice(deviceId));
      // connect(1s) + discoverServices(1s) + KVS flash read (instant in
      // the mock) before notifications begin; then ~2s of 20ms packets.
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);
      final firstCount = hub.totalSamples;
      expect(firstCount, greaterThan(0));

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isFalse);
      // Disconnect alone does not clear: a recording being finalized after a
      // drop may still be flushing data it snapshotted from the ring.
      expect(hub.totalSamples, firstCount);

      unawaited(link.connectToDevice(deviceId));
      // Setup again takes ~2s before notifications resume; just past it only
      // a few packets of the NEW stream can have arrived.
      async.elapse(const Duration(milliseconds: 3200));
      expect(link.isStreaming, isTrue);
      expect(hub.totalSamples, greaterThan(0));
      expect(hub.totalSamples, lessThan(firstCount));
      // Continuity was restarted: the mock's counter reset produced no
      // spurious drop.
      expect(hub.gaps.isEmpty, isTrue);

      teardown();
    });
  });

  test('a link drop forgets the dead device\'s board calibration', () {
    fakeAsync((async) {
      MockBlePlatform.instance.dropEveryNPackets = 0;
      final (hub, link, teardown) = wire(async: async);

      unawaited(link.connectToDevice(deviceId));
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);

      // Stand in for the connect-time calibration read landing on the hub.
      hub.updateBoardCalibration(
        BoardCalibration.parse(
          demoBoardCalibrationDoc,
          pgaGains: const [32, 32, 32, 32],
        ),
      );
      expect(hub.boardDataStatus, BoardDataStatus.ok);

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(seconds: 4));
      expect(hub.boardCalibration, isNull);
      expect(hub.boardDataStatus, BoardDataStatus.unreadable);

      teardown();
    });
  });
}
