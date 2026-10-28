import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/adc_protocol.dart';
import 'package:dynamite_app/services/data_hub.dart';

/// Build an `AdcConfigNetworkData` v1 struct: version u8, id u16, status
/// u16, mode u16, clock u16, pga u16 (little-endian).
Uint8List makeConfig({required int clock, required int pga}) {
  return Uint8List(11)
    ..[0] = 1
    ..[7] = clock & 0xFF
    ..[8] = clock >> 8
    ..[9] = pga & 0xFF
    ..[10] = pga >> 8;
}

void main() {
  group('parseAdcConfig', () {
    test(
      'the shipping configuration: all channels on, OSR 4096 → 1000 SPS',
      () {
        // CLOCK = 0x0F14: CH0-3 enabled, TBM clear, OSR field 101b (4096).
        final config = parseAdcConfig(makeConfig(clock: 0x0F14, pga: 0x0000))!;
        expect(config.sampleRateHz, 1000);
        expect(config.pgaGains, [1.0, 1.0, 1.0, 1.0]);
      },
    );

    test('PGA gains decode per 4-bit field as 2^field', () {
      // Fields ch0..ch3 = 0,1,2,4 → gains 1,2,4,16. Field value 5+ stays
      // masked to 3 bits like the shipping parser did.
      final config = parseAdcConfig(makeConfig(clock: 0x0F14, pga: 0x4210))!;
      expect(config.pgaGains, [1.0, 2.0, 4.0, 16.0]);
      expect(config.pgaGains.length, kAdcChannelCount);
    });

    test('every selectable OSR divides the modulator clock exactly', () {
      const expected = {
        0: 32000, // OSR 128
        1: 16000, // OSR 256
        2: 8000, // OSR 512
        3: 4000, // OSR 1024
        4: 2000, // OSR 2048
        5: 1000, // OSR 4096
        6: 500, // OSR 8192
        7: 250, // OSR 16384 (datasheet prints 16256 — a typo)
      };
      for (final MapEntry(key: field, value: rate) in expected.entries) {
        final config = parseAdcConfig(makeConfig(clock: field << 2, pga: 0))!;
        expect(config.sampleRateHz, rate, reason: 'OSR field $field');
      }
    });

    test('the TBM bit overrides the OSR field with 64 → 64000 SPS', () {
      final config = parseAdcConfig(makeConfig(clock: 0x20, pga: 0))!;
      expect(config.sampleRateHz, 64000);
      // TBM wins regardless of the OSR field's value.
      expect(
        parseAdcConfig(makeConfig(clock: 0x20 | (7 << 2), pga: 0))!
            .sampleRateHz,
        64000,
      );
    });

    test('a short buffer or unknown struct version fails the parse', () {
      expect(parseAdcConfig(Uint8List(10)), isNull);
      expect(
        parseAdcConfig(makeConfig(clock: 0x0F14, pga: 0)..[0] = 2),
        isNull,
      );
    });
  });

  group('production encoder ↔ AdcPacketDecoder round-trip', () {
    test('rails and a wrap-straddling counter anchor come back unchanged', () {
      final hub = DataHub();
      final decoder = AdcPacketDecoder(hub);

      // Signed 24-bit rails: ±(2^23 - 1) and -2^23, plus ordinary values.
      const frames = [
        [0x7FFFFF, -0x800000, -0x7FFFFF, 0],
        [123456, -123456, 1, -1],
        [0, 0x7FFFFF, -0x800000, 4000000],
        [-4000000, 42, -42, 0x7FFFFF],
        [-1, 1, 0, -0x7FFFFF],
        [7, 700, 7000, 70000],
      ];
      // A counter near the top of the 16-bit range: six samples carry it
      // exactly onto the wrap, so the continuation packet starts at 0.
      const counter = 0xFFFA;
      Uint8List packet(int counter, Iterable<List<int>> frames) =>
          encodeAdcPacket(
            counter: counter,
            frames: [for (final f in frames) encodeAdcFrame(f)],
          );
      decoder.onDataPacket(packet(counter, frames));
      // The starting counter anchored to hub index 0 — the pairing the live
      // session writer derives ssn_origin from.
      expect(hub.packetAnchor, (counter: counter, hubIndex: 0));
      decoder.onDataPacket(
        packet((counter + frames.length) & 0xFFFF, [
          const [-2, 20, -200, 2000],
          const [3, -30, 300, -3000],
        ]),
      );

      // The continuation's wrapped counter anchored in lockstep, right where
      // the first packet ended.
      expect(hub.packetAnchor, (counter: 0, hubIndex: frames.length));
      // Eight samples, and the 0xFFFF → 0 wrap injected no spurious gap.
      const expected = [
        ...frames,
        [-2, 20, -200, 2000],
        [3, -30, 300, -3000],
      ];
      expect(hub.totalSamples, expected.length);
      expect(hub.gaps.isEmpty, isTrue);
      for (var s = 0; s < expected.length; s++) {
        for (var c = 0; c < kAdcChannelCount; c++) {
          expect(hub.rawAt(c, s), expected[s][c], reason: 'sample $s ch $c');
        }
      }
    });

    test(
      'the wire layout itself: 16-bit LE counter, then 24-bit LE channels in '
      'channel order',
      () {
        // Hand-rolled bytes, independent of [encodeAdcPacket]/[encodeAdcFrame]:
        // a shared offset, endianness or channel-order mistake in the encoder
        // and the decoder would otherwise agree with itself.
        final bytes = Uint8List(wireAdcHeaderSize + 2 * wireAdcSampleLength);
        // Counter 0x1234, little-endian.
        bytes[0] = 0x34;
        bytes[1] = 0x12;
        // Frame 0: ch0 = 0x000001, ch1 = 0x000100, ch2 = 0x010000, ch3 = 2.
        // Each value least-significant byte first, channels back to back.
        const frame0 = [
          0x01, 0x00, 0x00, // ch0
          0x00, 0x01, 0x00, // ch1
          0x00, 0x00, 0x01, // ch2
          0x02, 0x00, 0x00, // ch3
        ];
        // Frame 1: ch0 = -1 (0xFFFFFF), ch1 = -2^23, ch2/ch3 = 0.
        const frame1 = [
          0xFF, 0xFF, 0xFF, // ch0
          0x00, 0x00, 0x80, // ch1
          0x00, 0x00, 0x00, // ch2
          0x00, 0x00, 0x00, // ch3
        ];
        bytes.setAll(wireAdcHeaderSize, frame0);
        bytes.setAll(wireAdcHeaderSize + wireAdcSampleLength, frame1);

        final hub = DataHub();
        AdcPacketDecoder(hub).onDataPacket(bytes);

        expect(hub.packetAnchor, (counter: 0x1234, hubIndex: 0));
        expect(hub.totalSamples, 2);
        expect(
          [for (var c = 0; c < kAdcChannelCount; c++) hub.rawAt(c, 0)],
          [0x000001, 0x000100, 0x010000, 2],
        );
        expect(
          [for (var c = 0; c < kAdcChannelCount; c++) hub.rawAt(c, 1)],
          [-1, -0x800000, 0, 0],
        );
      },
    );
  });
}
