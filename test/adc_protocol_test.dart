import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/adc_protocol.dart';

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
        parseAdcConfig(
          makeConfig(clock: 0x20 | (7 << 2), pga: 0),
        )!.sampleRateHz,
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
}
