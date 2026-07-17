import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/bt_device_config.dart';
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

  group('MockBlePlatform scan', () {
    test('startScan honors ScanFilter.withServices', () {
      fakeAsync((async) {
        UniversalBle.setInstance(MockBlePlatform.instance);
        final seen = <String>[];
        UniversalBle.onScanResult = (d) => seen.add(d.deviceId);

        unawaited(
          UniversalBle.startScan(
            scanFilter: ScanFilter(withServices: [btServiceId]),
          ),
        );
        // The mock emits results on a 1s periodic timer.
        async.elapse(const Duration(seconds: 3));
        unawaited(UniversalBle.stopScan());
        async.elapse(const Duration(milliseconds: 100));

        expect(seen, isNotEmpty);
        // Only device '2' advertises btServiceId.
        expect(seen.toSet(), {'2'});
      });
    });
  });

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

    test('induced drops surface as the expected ranges in DataHub.gaps', () {
      fakeAsync((async) {
        // Every 3rd generated packet is dropped (counter still advances), so
        // one packet (20 samples) goes missing each time and the decoder reports
        // it via addDroppedFrames.
        MockBlePlatform.instance.dropEveryNPackets = 3;
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));

        expect(link.isStreaming, isTrue);
        expect(hub.gaps.isEmpty, isFalse);
        // The first induced drop lands at samples [60, 80): packets 0/1/2 cover
        // [0,20)/[20,40)/[40,60); packet 3 (counter 60) is dropped, packet 4
        // (counter 80) is one stride past the expected 60 -> 20 dropped.
        expect(hub.gaps.contains(60), isTrue);
        expect(hub.gaps.contains(79), isTrue);
        expect(hub.gaps.contains(80), isFalse);
        // The gap holds the previous real value (a synthetic frame value),
        // never NaN or an out-of-range read.
        expect(hub.rawData[0][60 % DataHub.maxDataSz], isA<int>());

        teardown();
      });
    });

    test('disconnect cancels the feed (no more samples arrive)', () {
      fakeAsync((async) {
        MockBlePlatform.instance.dropEveryNPackets = 0;
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));
        expect(link.isStreaming, isTrue);
        final countAtDisconnect = hub.totalSamples;

        unawaited(link.disconnectSelectedDevice());
        async.elapse(const Duration(seconds: 4));
        // No new samples after teardown stopped the notification timer.
        expect(hub.totalSamples, countAtDisconnect);
        expect(link.isStreaming, isFalse);
      });
    });
  });
}
