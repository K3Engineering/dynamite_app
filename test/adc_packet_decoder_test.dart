import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/adc_protocol.dart';
import 'package:dynamite_app/services/data_hub.dart';

/// Builds a 242-byte ADC-feed notification packet (the exact wire format the
/// device emits and [AdcPacketDecoder] consumes):
///   bytes 0..1 : 16-bit little-endian running sample counter ([startCounter])
///   then [nwAdcNumSamples] samples of [nwAdcSampleLength] bytes each, where
///   each channel value is packed as 3 bytes little-endian (24-bit signed).
Uint8List makePacket(int startCounter, int Function(int s, int c) value) {
  final ev = Uint8List(nwHeaderSize + nwAdcSampleLength * nwAdcNumSamples);
  ev[0] = startCounter & 0xFF;
  ev[1] = (startCounter >> 8) & 0xFF;
  for (int s = 0; s < nwAdcNumSamples; ++s) {
    for (int c = 0; c < nwNumAdcChan; ++c) {
      final v = value(s, c) & 0xFFFFFF;
      final base = nwHeaderSize + s * nwAdcSampleLength + c * 3;
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
    test('a well-formed packet appends nwAdcNumSamples samples', () {
      decoder.onDataPacket(makePacket(0, (s, c) => c * 10));
      expect(hub.totalSamples, nwAdcNumSamples);
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
      expect(hub.rawData[0][nwAdcNumSamples - 1], 10);
    });

    test('consecutive packets with counter += nwAdcNumSamples report no gap',
        () {
      decoder.onDataPacket(makePacket(0, (s, c) => 1));
      decoder.onDataPacket(makePacket(nwAdcNumSamples, (s, c) => 2));
      decoder.onDataPacket(makePacket(2 * nwAdcNumSamples, (s, c) => 3));

      expect(hub.totalSamples, 3 * nwAdcNumSamples);
      expect(hub.gaps.contains(0), isFalse);
      expect(hub.gaps.contains(nwAdcNumSamples), isFalse);
      expect(hub.gaps.contains(2 * nwAdcNumSamples), isFalse);
    });

    test('a counter jump injects the dropped range into DataHub.gaps', () {
      // Packet 0 covers samples [0, 20) (counter = 0). The next packet's
      // counter is 2 * nwAdcNumSamples (40), one stride beyond the expected 20,
      // so the decoder reports 20 dropped samples before decoding the new one.
      decoder.onDataPacket(makePacket(0, (s, c) => 1));
      final before = hub.totalSamples; // 20
      decoder.onDataPacket(makePacket(2 * nwAdcNumSamples, (s, c) => 5));

      // 20 held (gap) samples + 20 real samples from the second packet.
      expect(hub.totalSamples, before + 2 * nwAdcNumSamples);
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
      const next = (start + nwAdcNumSamples) & 0xFFFF; // wraps to 0x0004
      decoder.onDataPacket(makePacket(start, (s, c) => 7));
      decoder.onDataPacket(makePacket(next, (s, c) => 8));

      expect(hub.totalSamples, 2 * nwAdcNumSamples);
      expect(hub.gaps.contains(start), isFalse);
    });

    test('resetContinuity suppresses the diff against a stale counter', () {
      decoder.onDataPacket(makePacket(0, (s, c) => 1));
      // Without a reset, this huge jump would report ~65000 dropped samples.
      decoder.resetContinuity();
      decoder.onDataPacket(makePacket(0x7FFF, (s, c) => 2));

      expect(hub.totalSamples, 2 * nwAdcNumSamples);
      expect(hub.gaps.contains(nwAdcNumSamples), isFalse);
    });

    test('an empty packet is ignored', () {
      decoder.onDataPacket(Uint8List(0));
      expect(hub.totalSamples, 0);
    });
  });
}
