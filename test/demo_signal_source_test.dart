import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/adc_protocol.dart';
import 'package:dynamite_app/services/adc_packet_decoder.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/demo_signal_source.dart';

void main() {
  test(
    'DemoSignalSource emits continuous, well-formed packets into decoder',
    () async {
      final hub = DataHub();
      final decoder = AdcPacketDecoder(hub);
      final demoSource = DemoSignalSource();

      final List<Uint8List> packets = [];
      demoSource.start(packets.add);

      // Wait for a few timer ticks to collect packets
      await Future<void>.delayed(const Duration(milliseconds: 100));
      demoSource.stop();

      expect(
        packets.isNotEmpty,
        isTrue,
        reason: 'DemoSource should emit packets',
      );

      // Run the generated packets sequentially into the mock Hub through Decoder
      for (final p in packets) {
        decoder.onDataPacket(p);
      }

      // Verify continuity: hub.addDroppedFrames should NOT have been called.
      // However, since we mock DataHub's real usage, DataHub would register dropped frames internally,
      // though DataHub does not expose droppedFrames directly for this test easily, we know
      // DataHub totalSamples should exactly equal packets.length * 20
      final expectedSamples = packets.length * nwAdcNumSamples;

      // totalSamples advances exactly if there are no gaps
      expect(
        hub.totalSamples,
        expectedSamples,
        reason:
            'No samples should be dropped, total should match emitted frames exactly.',
      );
    },
  );
}
