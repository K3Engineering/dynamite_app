import 'dart:async';
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

  group('LiveSessionWriter ring-buffer safety', () {
    void pumpSamples(DataHub hub, Int32List frame, int count, int value) {
      for (int ch = 0; ch < channels; ch++) {
        frame[ch] = value;
      }
      for (int i = 0; i < count; i++) {
        hub.addSampleFrame(frame);
      }
    }

    test('a slice is snapshotted at call time, not at dequeue time', () async {
      final saved = <Uint8List>[];
      final writer = LiveSessionWriter(
        1,
        Float64List(channels),
        chunkSink: (sessionId, chunkIndex, data) async => saved.add(data),
      );
      final hub = DataHub();
      final frame = Int32List(channels);
      const n = 50;
      for (int i = 0; i < n; i++) {
        for (int ch = 0; ch < channels; ch++) {
          frame[ch] = i;
        }
        hub.addSampleFrame(frame);
      }

      // Enqueue, then keep the producer busy before the queued op can drain
      // (it runs in a microtask, which this synchronous pump never yields to).
      unawaited(writer.appendData(hub, 0, n));
      pumpSamples(hub, frame, 1000, 100000); // much larger values, no wrap

      await writer.flush();
      expect(writer.hasError, isFalse);
      expect(writer.totalSamplesRecorded, n);
      expect(writer.peakRaw, n - 1); // not 100000: the slice was snapshotted

      // The persisted chunk holds the call-time values, byte for byte.
      expect(saved, hasLength(1));
      final stored = ByteData.sublistView(saved.single);
      expect(stored.lengthInBytes, n * channels * 4);
      for (int s = 0; s < n; s++) {
        for (int ch = 0; ch < channels; ch++) {
          expect(stored.getInt32((s * channels + ch) * 4, Endian.little), s);
        }
      }
    });

    test('a full-ring storage stall latches an error and truncates the '
        'recording instead of persisting wrapped data', () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      final saved = <Uint8List>[];
      var sinkCalls = 0;
      final writer = LiveSessionWriter(
        1,
        Float64List(channels),
        chunkSink: (sessionId, chunkIndex, data) async {
          sinkCalls++;
          if (!entered.isCompleted) entered.complete();
          await gate.future; // wedge every chunk write until released
          saved.add(data);
        },
      );
      final hub = DataHub();
      final frame = Int32List(channels);

      // Fill the staging buffer past the 16 KB flush threshold so the first
      // chunk write goes in flight and blocks inside the sink.
      const chunkSamples = 2048; // 2048 * 4 ch * 4 B = 32 KB > 16 KB
      pumpSamples(hub, frame, chunkSamples, 7);
      unawaited(writer.appendData(hub, 0, chunkSamples));
      await entered.future; // the queue is now stuck behind the gated write

      // Enqueue one more slice, then simulate the producer running for a
      // whole ring while storage stays stalled: this slice's ring slots get
      // overwritten before its queued op ever runs.
      pumpSamples(hub, frame, 100, 42);
      unawaited(writer.appendData(hub, chunkSamples, 100));
      pumpSamples(hub, frame, DataHub.maxDataSz, 66666); // ring wrap

      gate.complete();
      await writer.flush();

      // The backpressure latch must trip on the stale slice: it is dropped
      // (never reaches the sink), the error is latched for the controller's
      // auto-stop path, and only the pre-stall chunk was persisted.
      expect(writer.hasError, isTrue);
      expect(writer.writeError, isA<StateError>());
      expect(writer.totalSamplesRecorded, chunkSamples);
      expect(writer.peakRaw, 7); // wrapped (66666) data never scanned
      expect(sinkCalls, 1);
      expect(saved, hasLength(1));
      expect(saved.single.lengthInBytes, chunkSamples * channels * 4);
    });
  });
}
