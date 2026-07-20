import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/mockble.dart';
import 'package:dynamite_app/services/recording_controller.dart';

/// The hub must start fresh on every new device stream: connecting (even to
/// the same device) clears the previous stream's ring buffer, peaks and gaps,
/// and restarts packet-continuity tracking so the new stream's first packet
/// isn't diffed against the old stream's counter.
///
/// Same mock-BLE + fakeAsync harness as mockble_test.dart, with a
/// [RecordingController] added — its link observation performs the reset.
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
    final recording = RecordingController(
      dataHub: hub,
      linkManager: link,
      decoder: decoder,
      events: events,
    );

    return (
      hub,
      link,
      () {
        recording.dispose();
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
      // connect(1s) + discoverServices(1s) + read calibration(1s) = 3s before
      // notifications begin; then ~1s of 20ms packets.
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isTrue);
      final firstCount = hub.totalSamples;
      expect(firstCount, greaterThan(0));

      unawaited(link.disconnectSelectedDevice());
      async.elapse(const Duration(seconds: 4));
      expect(link.isStreaming, isFalse);
      // Disconnect alone does not clear: a recording being finalized after a
      // drop may still be reading the ring buffer.
      expect(hub.totalSamples, firstCount);

      unawaited(link.connectToDevice(deviceId));
      // Setup again takes ~3s before notifications resume; just past it only
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
}
