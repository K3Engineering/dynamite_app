import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/bt_scan.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/app_events.dart';
import 'package:dynamite_app/services/ble_link_manager.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'helpers/flash_docs.dart';
import 'helpers/mockble.dart';

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
    final link = BleLinkManager(
      events: events,
      onDeviceFlash: (flash) => hub.updateBoardCalibration(flash.board),
      onAdcData: decoder.onDataPacket,
      onSampleRate: (_) {},
    );

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
        final board = hub.boardCalibration! as ProvisionedBoardCalibration;
        expect(board.channels.every((c) => c.isCalibrated), isTrue);
        expect(
          (board.channels[0] as CalibratedChannelBoard).offsetCounts,
          closeTo(845.2, 1e-9),
        );

        teardown();
      });
    });

    test('an unprovisioned board (empty KVS) streams raw-only', () {
      fakeAsync((async) {
        MockBlePlatform.instance.seedKvs(kvsFromDoc(''));
        addTearDown(() => MockBlePlatform.instance.resetKnobs());
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));

        // An EMPTY KVS is a working channel with no data, not a failure:
        // dev boards with no provisioning stay usable. The empty document
        // turns into the unprovisioned verdict (raw counts only).
        expect(link.isStreaming, isTrue);
        expect(hub.totalSamples, greaterThan(0));
        expect(hub.boardCalibration, isA<UnprovisionedBoardCalibration>());

        teardown();
      });
    });

    test('a partially provisioned board (constants, no calibration) streams '
        'mV/V on the nominal chain', () {
      fakeAsync((async) {
        MockBlePlatform.instance.seedKvs(
          kvsFromDoc(
            'adc_fsr=1.2,nominal\nexc=4.53,nominal\nafe_gain=101,nominal',
          ),
        );
        addTearDown(() => MockBlePlatform.instance.resetKnobs());
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));

        // The board knows what it is — constants resolved, a provisioned
        // board — but was never factory-calibrated: every channel converts
        // through the nominal chain, so raw and mV/V work while force
        // units stay cell-gated.
        expect(link.isStreaming, isTrue);
        final board = hub.boardCalibration! as ProvisionedBoardCalibration;
        expect(board.isCalibrated, isFalse);
        expect(hub.currentValue(0, DisplayUnit.mVv), isNotNull);
        expect(hub.currentValue(0, DisplayUnit.kN), isNull);

        teardown();
      });
    });

    test('present-but-invalid Factory flash streams raw on an invalid board', () {
      fakeAsync((async) {
        // A corrupt board half: the app refuses to adopt it, but the device
        // still connects and streams raw counts with an invalid-board marker
        // (the banner names the reason) — never a soft-brick.
        for (final doc in [
          'adc_fsr=1.2,nominal\nexc=4.53,nominal', // afe_gain missing
          'adc_fsr=1.2,nominal\nexc=soon\nafe_gain=101', // bad value
          'adc_fsr=1.2\nexc=4.53\nafe_gain=101\nch0.r=1,2,3,4,5,6', // no cal.date
        ]) {
          MockBlePlatform.instance.seedKvs(kvsFromDoc(doc));
          final (hub, link, teardown) = wire(async: async);

          unawaited(link.connectToDevice(deviceId));
          async.elapse(const Duration(seconds: 4));

          expect(link.isStreaming, isTrue, reason: doc);
          expect(link.linkState, BtLinkState.streaming, reason: doc);
          expect(
            hub.boardCalibration,
            isA<InvalidBoardCalibration>(),
            reason: doc,
          );
          expect(hub.totalSamples, greaterThan(0), reason: doc);

          teardown();
        }
        addTearDown(() => MockBlePlatform.instance.resetKnobs());
      });
    });

    test('a degenerate slot reads as empty; the connection succeeds', () {
      fakeAsync((async) {
        // The app owns the slot keys, so an unparseable value is not
        // corruption to abort for: the slot reads as empty (force units
        // report unavailable), and a save reconciles the device.
        MockBlePlatform.instance.seedKvs(
          kvsFromDoc(
            'adc_fsr=1.2\nexc=4.53\nafe_gain=101\nlc0.cap=100\nlc0.sens=abc',
          ),
        );
        addTearDown(() => MockBlePlatform.instance.resetKnobs());
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));

        expect(link.isStreaming, isTrue);
        expect(hub.boardCalibration, isA<ProvisionedBoardCalibration>());
        // ch0 has no cell: force units report unavailable, electrical ones
        // convert through the nominal chain.
        expect(hub.currentValue(0, DisplayUnit.mVv), isNotNull);
        expect(hub.currentValue(0, DisplayUnit.kN), isNull);

        teardown();
      });
    });

    test('unknown future metadata keys are ignored', () {
      fakeAsync((async) {
        MockBlePlatform.instance.seedKvs(
          kvsFromDoc('$demoBoardCalibrationDoc\ncharging=enabled\n'),
        );
        final (hub, link, teardown) = wire(async: async);

        unawaited(link.connectToDevice(deviceId));
        async.elapse(const Duration(seconds: 4));

        expect(link.isStreaming, isTrue);
        expect(hub.boardCalibration, isA<ProvisionedBoardCalibration>());

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
