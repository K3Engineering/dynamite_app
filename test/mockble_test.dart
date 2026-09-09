import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/display_unit.dart';
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
  /// installed. Returns the hub to inspect and a teardown that disconnects
  /// (cancelling the feed timer) and clears state so the singleton mock is
  /// reusable across tests.
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
    test(
      'connect -> decode -> DataHub with no gaps (dropEveryNPackets = 0)',
      () {
        fakeAsync((async) {
          MockBlePlatform.instance.dropEveryNPackets = 0;
          final (hub, link, teardown) = wire(async: async);

          unawaited(link.connectToDevice(deviceId));
          // connect(1s) + discoverServices(1s) + KVS flash read (instant in
          // the mock) before notifications begin; then ~2s of 20ms packets.
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
          expect(hub.rawAt(0, 0), 0);
          expect(hub.rawAt(2, 0), 2500000);
          expect(hub.rawAt(3, 0), -2000000);

          teardown();
          expect(link.isStreaming, isFalse);
        });
      },
    );

    test('connect reads the factory calibration into the hub', () {
      fakeAsync((async) {
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));

        expect(link.isStreaming, isTrue);
        expect(
          hub.boardCalibration!.channels.every((c) => c.isFactoryCalibrated),
          isTrue,
        );
        expect(
          hub.boardCalibration!.channels[0].offsetCounts,
          closeTo(845.2, 1e-9),
        );

        teardown();
      });
    });

    test('an unprovisioned board (empty KVS) streams raw-only', () {
      fakeAsync((async) {
        MockBlePlatform.instance.seedKvsFromDoc('');
        addTearDown(() => MockBlePlatform.instance.resetKnobs());
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));

        // An EMPTY KVS is a working channel with no data, not a failure:
        // dev boards with no provisioning stay usable. The empty document
        // turns into the unprovisioned verdict (raw counts only).
        expect(link.isStreaming, isTrue);
        expect(hub.totalSamples, greaterThan(0));
        expect(hub.boardDataStatus, BoardDataStatus.unprovisioned);

        teardown();
      });
    });

    test('a partially provisioned board (constants, no calibration) streams '
        'mV/V on the nominal chain', () {
      fakeAsync((async) {
        MockBlePlatform.instance.seedKvsFromDoc(
          'adc_fsr=1.2,nominal\nexc=4.53,nominal\nafe_gain=101,nominal',
        );
        addTearDown(() => MockBlePlatform.instance.resetKnobs());
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));

        // The board knows what it is (board constants resolve — the ok
        // verdict, not the unprovisioned raw-only notice) but was never
        // factory-calibrated: every channel is uncalibrated and converts
        // through the nominal chain, so raw and mV/V work while force
        // units stay cell-gated.
        expect(link.isStreaming, isTrue);
        final board = hub.boardCalibration!;
        expect(board.constantsStatus, BoardDataStatus.ok);
        expect(board.isFactoryCalibrated, isFalse);
        expect(board.calDataInvalid, isFalse);
        expect(hub.currentValue(0, DisplayUnit.mVv), isNotNull);
        expect(hub.currentValue(0, DisplayUnit.kN), isNull);

        teardown();
      });
    });

    test('a failing KVS channel fails the connection (no streaming, no '
        'board data)', () {
      fakeAsync((async) {
        MockBlePlatform.instance.failKvsCommands = true;
        addTearDown(() => MockBlePlatform.instance.resetKnobs());
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));

        // A link without its KVS channel can't save rig slots or the device
        // name — it never advances to streaming (same verdict as an
        // unreadable ADC config), so the hub sees no samples at all.
        expect(link.isStreaming, isFalse);
        expect(hub.totalSamples, 0);
        expect(hub.boardCalibration, isNull);

        teardown();
      });
    });
  });
}
