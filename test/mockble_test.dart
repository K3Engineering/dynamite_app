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

/// End-to-end (no hardware) test of the live data pipeline:
///   MockBlePlatform (wire format) -> BleLinkManager -> AdcPacketDecoder ->
///   DataHub.
///
/// The mock emits packets on a periodic [Timer]; we drive that timer (and the
/// mock's connect/discover/subscribe delays) deterministically with [fakeAsync]
/// so no real time passes. This locks the mock to the real wire format: if it
/// ever drifts from adc_protocol.dart again, the decoder will assert / misparse
/// and these tests catch it.
void main() {
  // The mock device that advertises the ADC service (see _generateServices).
  const deviceId = '2';

  /// Builds the same object graph as main.dart, but with the mock platform
  /// installed regardless of [useMockBt]. Returns the hub to inspect and a
  /// teardown that disconnects (cancelling the feed timer) and clears state so
  /// the singleton mock is reusable across tests.
  (DataHub, BleLinkManager, VoidCallback) wire({required FakeAsync async}) {
    UniversalBle.setInstance(MockBlePlatform.instance);
    final events = AppEvents();
    final hub = DataHub();
    final decoder = AdcPacketDecoder(hub);
    final link = BleLinkManager(events: events)
      ..onAdcData = decoder.onDataPacket
      ..onCalibrationData = decoder.onCalibrationPacket;

    return (
      hub,
      link,
      () {
        // Best-effort disconnect so the mock's notification/RSSI timers are
        // cancelled and the singleton is left idle for the next test.
        unawaited(link.disconnectSelectedDevice());
        async.elapse(const Duration(seconds: 4));
      },
    );
  }

  group('MockBlePlatform feed round-trip', () {
    test('connect -> decode -> DataHub with no gaps (dropEveryNPackets = 0)', () {
      fakeAsync((async) {
        MockBlePlatform.instance.dropEveryNPackets = 0;
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        // connect(1s) + discoverServices(1s) + read calibration(1s) = 3s before
        // notifications begin; then ~1s of 20ms packets.
        async.elapse(const Duration(seconds: 4));

        expect(link.isStreaming, isTrue);
        expect(hub.totalSamples, greaterThan(0));
        // ~50 packets * 20 samples in the final second.
        expect(hub.totalSamples, greaterThanOrEqualTo(20 * 40));
        // No dropped packets at all.
        expect(hub.gaps.isEmpty, isTrue);

        // Spot-check decoded values against the synthetic waveform's frame 0:
        //   ch0 = sin(0)*4e6 = 0, ch2 = cos(0)*2.5e6 = 2500000,
        //   ch3 = (0 % 200 - 100) * 20000 = -2000000.
        expect(hub.rawData[0][0], 0);
        expect(hub.rawData[2][0], 2500000);
        expect(hub.rawData[3][0], -2000000);

        teardown();
        expect(link.isStreaming, isFalse);
      });
    });

    test('connect reads the factory calibration into the hub', () {
      fakeAsync((async) {
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));

        expect(link.isStreaming, isTrue);
        expect(
          hub.boardCalibration.channels.every((c) => c.isFactoryCalibrated),
          isTrue,
        );
        expect(
          hub.boardCalibration.channels[0].offsetCounts,
          closeTo(845.2, 1e-9),
        );

        teardown();
      });
    });

    test(
      'a failed calibration read leaves nominal values and still streams',
      () {
        fakeAsync((async) {
          MockBlePlatform.instance.failCalibrationRead = true;
          addTearDown(
            () => MockBlePlatform.instance.failCalibrationRead = false,
          );
          final (hub, link, teardown) = wire(async: async);

          unawaited(link.connectToDevice(deviceId));
          async.elapse(const Duration(seconds: 4));

          // Best-effort by design: the stream must come up regardless.
          expect(link.isStreaming, isTrue);
          expect(hub.totalSamples, greaterThan(0));
          expect(
            hub.boardCalibration.channels.every((c) => !c.isFactoryCalibrated),
            isTrue,
          );

          teardown();
        });
      },
    );
  });
}
