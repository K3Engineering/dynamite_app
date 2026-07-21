import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/force_unit.dart';
import 'package:dynamite_app/services/data_hub.dart';

/// Unit tests for the hub's per-stream lifecycle (peaks, tare, reset). Uses
/// [ForceUnit.raw] throughout so forces equal tare-adjusted raw counts.
void main() {
  const int channels = DataHub.numAdcChannels;

  Int32List frameOf(int value) =>
      Int32List(channels)..fillRange(0, channels, value);

  void feed(DataHub hub, Int32List frame, int count) {
    for (int i = 0; i < count; i++) {
      hub.addSampleFrame(frame);
    }
  }

  group('peaks', () {
    test('an untouched hub reports zero peak/min, not sentinel garbage', () {
      final hub = DataHub();
      for (int ch = 0; ch < channels; ch++) {
        expect(hub.peakForce(ch, ForceUnit.raw), 0);
        expect(hub.minForce(ch, ForceUnit.raw), 0);
      }
    });

    test('cleared listeners fire on clear() only, not on sample appends', () {
      final hub = DataHub();
      var cleared = 0;
      void listener() => cleared++;
      hub.addClearedListener(listener);

      feed(hub, frameOf(7), 10);
      expect(cleared, 0);

      hub.clear();
      expect(cleared, 1);

      hub.removeClearedListener(listener);
      hub.clear();
      expect(cleared, 1);
    });

    test('a never-positive channel reports its true (negative) peak', () {
      final hub = DataHub();
      final frame = Int32List(channels);
      // Least negative = -50 (the true max), most negative = -300.
      for (final v in [-100, -300, -50, -200]) {
        frame[0] = v;
        hub.addSampleFrame(frame);
      }
      expect(hub.peakForce(0, ForceUnit.raw), -50);
      expect(hub.minForce(0, ForceUnit.raw), -300);
    });

    test('a never-negative channel reports its true (positive) min', () {
      final hub = DataHub();
      final frame = Int32List(channels);
      for (final v in [100, 300, 50, 200]) {
        frame[0] = v;
        hub.addSampleFrame(frame);
      }
      expect(hub.peakForce(0, ForceUnit.raw), 300);
      expect(hub.minForce(0, ForceUnit.raw), 50);
    });

    test('peaks are tare-adjusted at read time', () {
      final hub = DataHub();
      feed(hub, frameOf(1000), 10);
      hub.requestTare();
      feed(hub, frameOf(1000), 1024); // completes the tare at 1000
      expect(hub.peakForce(0, ForceUnit.raw), 0);
      expect(hub.minForce(0, ForceUnit.raw), 0);
    });
  });

  group('clear', () {
    test('resets every per-stream accumulation and notifies', () {
      final hub = DataHub();
      var notified = 0;
      hub.addListener(() => notified++);

      feed(hub, frameOf(1000), 50);
      hub.addDroppedFrames(20);
      hub.requestTare();
      feed(hub, frameOf(2000), 1024); // tare completes at 2000
      expect(hub.totalSamples, 50 + 20 + 1024);
      expect(hub.gaps.isEmpty, isFalse);

      hub.clear();
      expect(notified, greaterThan(0));
      expect(hub.totalSamples, 0);
      expect(hub.gaps.isEmpty, isTrue);
      expect(hub.taring, isFalse);
      expect(hub.tare[0], 0);
      expect(hub.peakForce(0, ForceUnit.raw), 0);
      expect(hub.minForce(0, ForceUnit.raw), 0);
      expect(hub.valueBuckets[0].series.samples, 0);
      expect(hub.diffBuckets[0].series.samples, 0);

      // New data starts a fresh timeline; the old extremes are gone.
      feed(hub, frameOf(-500), 10);
      expect(hub.totalSamples, 10);
      expect(hub.rawData[0][0], -500);
      expect(hub.peakForce(0, ForceUnit.raw), -500);
    });

    test('aborts an in-progress tare', () {
      final hub = DataHub();
      feed(hub, frameOf(100), 10);
      hub.requestTare();
      feed(hub, frameOf(100), 10);
      expect(hub.taring, isTrue);

      hub.clear();
      expect(hub.taring, isFalse);
      expect(hub.tare[0], 0);
    });
  });

  group('lastDataAt', () {
    test('commitBatch stamps the wall clock; clear resets it', () {
      final hub = DataHub();
      expect(hub.lastDataAt, isNull);

      feed(hub, frameOf(100), 20);
      hub.commitBatch(0);
      final stamped = hub.lastDataAt;
      expect(stamped, isNotNull);
      expect(DateTime.now().difference(stamped!).isNegative, isFalse);
      expect(DateTime.now().difference(stamped).inSeconds, lessThan(2));

      hub.clear();
      expect(hub.lastDataAt, isNull);
    });
  });

  group('tare', () {
    test('does not freeze the stream timeline', () {
      final hub = DataHub();
      feed(hub, frameOf(100), 100);
      hub.requestTare();
      feed(hub, frameOf(500), 1024);

      // Every tare-window sample was buffered and counted.
      expect(hub.totalSamples, 100 + 1024);
      expect(hub.rawData[0][100], 500); // first tare sample is in the ring
      expect(hub.rawData[0][100 + 1023], 500);
      expect(hub.taring, isFalse);
      expect(hub.tare[0], 500);
      expect(hub.currentForce(0, ForceUnit.raw), 0); // 500 - 500
    });

    test('recordings observe the samples appended during a tare', () {
      final hub = DataHub();
      final appended = <int>[];
      hub.addSamplesAppendedListener((start, count) => appended.add(count));

      // Mimic the decoder's per-packet pattern.
      void packet(int value, int frames) {
        final start = hub.totalSamples;
        feed(hub, frameOf(value), frames);
        hub.commitBatch(start);
      }

      packet(100, 20);
      hub.requestTare();
      packet(500, 1024);

      expect(appended, [20, 1024]);
      expect(hub.totalSamples, 20 + 1024);
    });

    test(
      'drops during a tare advance time and record gaps but never pollute the average',
      () {
        final hub = DataHub();
        feed(hub, frameOf(1000), 100);
        hub.requestTare();
        hub.addDroppedFrames(20); // held at 1000, mid-tare
        feed(hub, frameOf(500), 1024); // the 1024 REAL tare samples

        expect(hub.taring, isFalse);
        // Only real frames fed the average: exactly 500, despite 20 held
        // 1000s inside the window.
        expect(hub.tare[0], 500);
        // The drop is ordinary timeline: gap range + held values + counted.
        expect(hub.totalSamples, 100 + 20 + 1024);
        expect(hub.gaps.contains(100), isTrue);
        expect(hub.gaps.contains(119), isTrue);
        expect(hub.gaps.contains(120), isFalse);
        expect(hub.rawData[0][110], 1000); // held value inside the gap
      },
    );
  });
}
