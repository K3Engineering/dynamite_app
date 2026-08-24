import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/adc_protocol.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/demo_calibration.dart';

/// Default packet size for tests that don't care about it (the decoder
/// accepts any count).
const int defaultPacketSamples = 20;

/// Builds an ADC-feed notification: 16-bit LE sample counter plus [samples]
/// frames of [wireAdcSampleLength] bytes (24-bit LE per channel).
Uint8List makePacket(
  int startCounter,
  int Function(int s, int c) value, {
  int samples = defaultPacketSamples,
}) {
  final ev = Uint8List(wireAdcHeaderSize + wireAdcSampleLength * samples);
  ev[0] = startCounter & 0xFF;
  ev[1] = (startCounter >> 8) & 0xFF;
  for (int s = 0; s < samples; ++s) {
    for (int c = 0; c < kAdcChannelCount; ++c) {
      final v = value(s, c) & 0xFFFFFF;
      final base = wireAdcHeaderSize + s * wireAdcSampleLength + c * 3;
      ev[base] = v & 0xFF;
      ev[base + 1] = (v >> 8) & 0xFF;
      ev[base + 2] = (v >> 16) & 0xFF;
    }
  }
  return ev;
}

void main() {
  late DataHub hub;
  late AdcPacketDecoder decoder;

  setUp(() {
    hub = DataHub();
    decoder = AdcPacketDecoder(hub);
  });

  group('AdcPacketDecoder', () {
    test('a well-formed packet appends all its samples', () {
      decoder.onDataPacket(makePacket(0, (s, c) => c * 10));
      expect(hub.totalSamples, defaultPacketSamples);
    });

    test('decodes signed 24-bit values including negatives and extrema', () {
      // Per-sample channel values: 10, -10, max positive (0x7FFFFF),
      // min negative (-0x800000).
      int sampleValue(int s, int c) {
        switch (c) {
          case 0:
            return 10;
          case 1:
            return -10;
          case 2:
            return 0x7FFFFF;
          default:
            return -0x800000;
        }
      }

      decoder.onDataPacket(makePacket(0, sampleValue));

      expect(hub.rawData[0][0], 10);
      expect(hub.rawData[1][0], -10);
      expect(hub.rawData[2][0], 0x7FFFFF);
      expect(hub.rawData[3][0], -0x800000);
      // Every decoded sample in this packet is identical.
      expect(hub.rawData[0][defaultPacketSamples - 1], 10);
    });

    test('consecutive packets with counter += one packet report no gap', () {
      decoder.onDataPacket(makePacket(0, (s, c) => 1));
      decoder.onDataPacket(makePacket(defaultPacketSamples, (s, c) => 2));
      decoder.onDataPacket(makePacket(2 * defaultPacketSamples, (s, c) => 3));

      expect(hub.totalSamples, 3 * defaultPacketSamples);
      expect(hub.gaps.contains(0), isFalse);
      expect(hub.gaps.contains(defaultPacketSamples), isFalse);
      expect(hub.gaps.contains(2 * defaultPacketSamples), isFalse);
    });

    test('a counter jump injects the dropped range into DataHub.gaps', () {
      // Packet 0 covers samples [0, 20) (counter = 0). The next packet's
      // counter is 2 * defaultPacketSamples (40), one stride beyond the expected 20,
      // so the decoder reports 20 dropped samples before decoding the new one.
      decoder.onDataPacket(makePacket(0, (s, c) => 1));
      final before = hub.totalSamples; // 20
      decoder.onDataPacket(makePacket(2 * defaultPacketSamples, (s, c) => 5));

      // 20 held (gap) samples + 20 real samples from the second packet.
      expect(hub.totalSamples, before + 2 * defaultPacketSamples);
      // The dropped range is half-open [20, 40).
      expect(hub.gaps.contains(20), isTrue);
      expect(hub.gaps.contains(39), isTrue);
      expect(hub.gaps.contains(40), isFalse);
      // Held gap samples keep the previous real value (channel 0 was 1).
      expect(hub.rawData[0][20 % DataHub.maxDataSz], 1);
    });

    test('16-bit counter wraparound does not produce a spurious drop', () {
      // Start near the top of the 16-bit counter; the next packet's counter
      // is exactly one stride ahead, wrapping past 0xFFFF.
      const start = 0xFFF0;
      const next = (start + defaultPacketSamples) & 0xFFFF; // wraps to 0x0004
      decoder.onDataPacket(makePacket(start, (s, c) => 7));
      decoder.onDataPacket(makePacket(next, (s, c) => 8));

      expect(hub.totalSamples, 2 * defaultPacketSamples);
      expect(hub.gaps.contains(start), isFalse);
    });

    test('resetContinuity suppresses the diff against a stale counter', () {
      decoder.onDataPacket(makePacket(0, (s, c) => 1));
      // Without a reset, this huge jump would report ~65000 dropped samples.
      decoder.resetContinuity();
      decoder.onDataPacket(makePacket(0x7FFF, (s, c) => 2));

      expect(hub.totalSamples, 2 * defaultPacketSamples);
      expect(hub.gaps.contains(defaultPacketSamples), isFalse);
    });

    test('the packet counter anchors to the hub index after gap injection', () {
      // First packet: counter 0 lands at hub index 0.
      decoder.onDataPacket(makePacket(0, (s, c) => 1));
      expect(hub.packetAnchor, (counter: 0, hubIndex: 0));

      // A one-stride jump: 20 held samples are injected first, so the next
      // packet's first sample (counter 40) lands at hub index 40 — keeping
      // counter and hub timeline in lockstep (ssn = origin + row_index).
      decoder.onDataPacket(makePacket(2 * defaultPacketSamples, (s, c) => 5));
      expect(hub.packetAnchor, (
        counter: 2 * defaultPacketSamples,
        hubIndex: 2 * defaultPacketSamples,
      ));
    });

    test('a hub clear forgets the packet-counter anchor', () {
      decoder.onDataPacket(makePacket(100, (s, c) => 1));
      expect(hub.packetAnchor, isNotNull);

      hub.clear();
      expect(hub.packetAnchor, isNull);
    });

    test('a 14-sample packet decodes and advances continuity by 14', () {
      decoder.onDataPacket(makePacket(0, (s, c) => c + 1, samples: 14));
      decoder.onDataPacket(makePacket(14, (s, c) => c + 1, samples: 14));
      expect(hub.totalSamples, 28);
      expect(hub.gaps.contains(14), isFalse);
      expect(hub.rawData[0][0], 1);
      expect(hub.rawData[3][13], 4);
    });

    test('packets over 20 samples decode — the protocol caps nothing', () {
      decoder.onDataPacket(makePacket(0, (s, c) => c + 1, samples: 30));
      decoder.onDataPacket(makePacket(30, (s, c) => c + 1, samples: 30));
      expect(hub.totalSamples, 60);
      expect(hub.gaps.contains(30), isFalse);
      expect(hub.rawData[3][59], 4);
    });

    test('a header-only packet (counter, no samples) is malformed', () {
      decoder.onDataPacket(Uint8List(wireAdcHeaderSize));
      expect(hub.totalSamples, 0);
      expect(hub.lastMalformedPacketLen, wireAdcHeaderSize);
    });

    test('an empty packet is ignored and noted as malformed', () {
      decoder.onDataPacket(Uint8List(0));
      expect(hub.totalSamples, 0);
      expect(hub.lastMalformedPacketAt, isNotNull);
      expect(hub.lastMalformedPacketLen, 0);
    });

    test('a truncated packet is ignored, noted with its length, and never '
        'throws; leftover bytes are malformed', () {
      final full = makePacket(0, (s, c) => 1);
      decoder.onDataPacket(Uint8List.sublistView(full, 0, full.length - 1));
      expect(hub.totalSamples, 0);
      expect(hub.lastMalformedPacketLen, full.length - 1);
      decoder.onDataPacket(Uint8List(1));
      expect(hub.lastMalformedPacketLen, 1);
      final long = Uint8List(full.length + 3)..setAll(0, full);
      decoder.onDataPacket(long);
      expect(hub.totalSamples, 0);
      expect(hub.lastMalformedPacketLen, full.length + 3);
    });

    test('malformed packets never notify (the health display ticks on its '
        'own)', () {
      // noteMalformedPacket deliberately skips notifyListeners: a stream of
      // only-bad packets at 50 Hz would otherwise be a lot of rebuilds, and
      // the feed-health display re-derives on the live tab's 1 Hz tick.
      var notifyCount = 0;
      hub.addListener(() => notifyCount++);

      decoder.onDataPacket(Uint8List(0));
      decoder.onDataPacket(Uint8List(1));
      expect(notifyCount, 0);
      expect(hub.lastMalformedPacketLen, 1);
    });
  });

  group('AdcPacketDecoder clock cross-check', () {
    // Deterministic arrival clock: real packets arrive ~1 kHz / samples, and
    // the cross-check only cares about coarse (100 ms-scale) agreement.
    late int fakeUs;
    Duration clock() => Duration(microseconds: fakeUs);
    void advanceMs(int ms) => fakeUs += ms * 1000;

    setUp(() => fakeUs = 0);

    test('counter loss consistent with the clock injects the reported gap', () {
      final d = AdcPacketDecoder(hub, now: clock);
      d.onDataPacket(makePacket(0, (s, c) => 1));
      // ~1 s of silence: the device counted 1020 samples the link never
      // delivered, and the clock agrees within a packet interval.
      advanceMs(1040);
      d.onDataPacket(makePacket(1040, (s, c) => 2));

      expect(hub.totalSamples, 20 + 1020 + 20);
      expect(hub.gaps.contains(20), isTrue);
      expect(hub.gaps.contains(1039), isTrue);
      expect(hub.gaps.contains(1040), isFalse);
    });

    test('a loss spanning a full counter wrap is recovered from the clock', () {
      final d = AdcPacketDecoder(hub, now: clock);
      d.onDataPacket(makePacket(0, (s, c) => 1));
      // 65.5+ s of silence consumes a full counter wrap: the wire counter
      // moved by only the 20-sample remainder, which on the counter alone
      // would read as continuity.
      advanceMs(65556);
      d.onDataPacket(makePacket(65556 & 0xFFFF, (s, c) => 2));

      expect(hub.totalSamples, 20 + 65536 + 20);
      expect(hub.gaps.contains(20), isTrue);
      expect(hub.gaps.contains(20 + 65536 - 1), isTrue);
      expect(hub.gaps.contains(20 + 65536), isFalse);
    });

    test('a counter jump the clock rules out injects the clock-sized gap, '
        'and the next packet diffs the new numbering', () {
      final d = AdcPacketDecoder(hub, now: clock);
      d.onDataPacket(makePacket(0, (s, c) => 1));
      // 4 s since the previous packet but the counter restarted near 0 (a
      // firmware counter bug): no wrap count gets the 65521 modulo-delta
      // into 4000, so the clock is the authority. NOT a malformed packet —
      // the framing is fine, only the counter disagrees.
      advanceMs(4000);
      d.onDataPacket(makePacket(5, (s, c) => 2));

      expect(hub.lastMalformedPacketAt, isNull);
      expect(hub.totalSamples, 20 + 4000 + 20);
      expect(hub.gaps.contains(20), isTrue);
      expect(hub.gaps.contains(20 + 4000 - 1), isTrue);
      expect(hub.gaps.contains(20 + 4000), isFalse);

      advanceMs(20);
      d.onDataPacket(makePacket(5 + defaultPacketSamples, (s, c) => 3));
      expect(hub.totalSamples, 4040 + 20);
      expect(hub.gaps.contains(4040), isFalse);
    });

    test('sub-tolerance counter jumps stay plain gaps; beyond-tolerance ones '
        'fall back to the clock', () {
      final d = AdcPacketDecoder(hub, now: clock);
      d.onDataPacket(makePacket(0, (s, c) => 1));

      // No time passed and the counter jumped 2900 samples: inside the
      // 3 s slack, so it remains a plain counter-reported gap.
      d.onDataPacket(makePacket(20 + 2900, (s, c) => 2));
      expect(hub.totalSamples, 20 + 2900 + 20);

      // One beyond the slack with zero elapsed: counter/clock disagreement.
      // Zero clock samples elapsed, so the injected (clock-sized) gap is
      // empty — the packet just appends its own samples.
      d.onDataPacket(makePacket(2920 + 20 + 3101, (s, c) => 3));
      expect(hub.totalSamples, 2940 + 20);
      expect(hub.lastMalformedPacketAt, isNull);
    });

    test('a delivery stall inside the slack injects nothing', () {
      final d = AdcPacketDecoder(hub, now: clock);
      d.onDataPacket(makePacket(0, (s, c) => 1));
      // 2 s of silence, then the very next counter value: the clock says
      // 2000 samples of wall time passed but the counter says the stream is
      // continuous. That disagreement (2 s) is what the slack absorbs —
      // delivery jank on a healthy stream, so no gap.
      advanceMs(2000);
      d.onDataPacket(makePacket(defaultPacketSamples, (s, c) => 2));

      expect(hub.totalSamples, 2 * defaultPacketSamples);
      expect(hub.gaps.contains(defaultPacketSamples), isFalse);
    });
  });

  group('AdcPacketDecoder calibration', () {
    test('a calibration document populates the hub board calibration', () {
      decoder.onCalibrationPacket(
        Uint8List.fromList(utf8.encode(demoBoardCalibrationDoc)),
        const [1, 1, 1, 1],
      );
      final board = hub.boardCalibration;
      expect(board, isNotNull);
      expect(board!.channels.every((c) => c.isFactoryCalibrated), isTrue);
      expect(board.channels[0].offsetCounts, closeTo(845.2, 1e-9));
      expect(board.channels[2].offsetCounts, closeTo(1502.8, 1e-9));
      expect(board.factoryDate, '2026-07-20');
      expect(board.excitationMv, closeTo(4530.24, 1e-9));
      // The demo doc carries board constants: the verdict is ok.
      expect(board.constantsStatus, BoardDataStatus.ok);
      expect(board.channels[0].nominals, isNotNull);
    });

    test('a garbage read degrades to nominal without throwing', () {
      // Not valid UTF-8, let alone a calibration document.
      decoder.onCalibrationPacket(
        Uint8List.fromList(const [0x00, 0x9F, 0x92, 0x96, 0xFF]),
        const [1, 1, 1, 1],
      );
      expect(
        hub.boardCalibration!.channels.every((c) => !c.isFactoryCalibrated),
        isTrue,
      );
      // No constants keys in the garbage: unprovisioned, raw-only.
      expect(hub.boardDataStatus, BoardDataStatus.unprovisioned);
    });
  });
}
