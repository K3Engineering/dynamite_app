import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/session_storage.dart';

/// Peak-bias tests for the storage side: a never-positive stream must report
/// its true (negative) max, both for loaded sessions and for the live
/// writer's streaming aggregate. No DB is touched: the writer's append stays
/// under its flush threshold, so nothing is ever persisted.
void main() {
  const int channels = DataHub.numAdcChannels;

  group('SessionData.peakRaw', () {
    SessionData makeSession(List<int> values) => SessionData(
      channels: [
        for (int ch = 0; ch < channels; ch++) Int32List.fromList(values),
      ],
      sampleRate: DataHub.samplesPerSec,
      sampleCount: values.length,
      calibrationSlope: 1.0,
      calibrationOffset: 0,
      tares: List.filled(channels, 0.0),
    );

    test('a never-positive channel reports its true (negative) peak', () {
      final sess = makeSession([-100, -300, -50, -200]);
      expect(sess.peakRaw(0), -50);
    });

    test('an empty session reports 0', () {
      final sess = makeSession(const []);
      expect(sess.peakRaw(0), 0);
    });
  });

  group('LiveSessionWriter peak scan', () {
    test('a never-positive stream yields a negative stored peak', () async {
      final hub = DataHub();
      final frame = Int32List(channels);
      const n = 50;
      for (int i = 0; i < n; i++) {
        for (int ch = 0; ch < channels; ch++) {
          frame[ch] = -1000 + i; // least negative: -951 at i = 49
        }
        hub.addSampleFrame(frame);
      }

      final writer = LiveSessionWriter(1, Float64List(channels));
      await writer.appendData(hub, 0, n);

      expect(writer.totalSamplesRecorded, n);
      expect(writer.peakRaw, -1000 + n - 1);
    });
  });
}
