import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/hub_event.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/demo_calibration.dart';

/// Unit tests for the hub's per-stream lifecycle (peaks, tare, reset). Uses
/// [DisplayUnit.raw] throughout so forces equal tare-adjusted raw counts.
void main() {
  const int channels = kAdcChannelCount;

  /// Pro-like test chain, reproducing the app's former compiled constants.
  const testNominals = ChannelNominals(
    adcFsrV: 1.2,
    afeGain: 101,
    pgaGain: 1,
    excitationV: 4.53,
  );

  /// A board whose channels all convert through the nominal chain.
  BoardCalibration nominalBoard() => BoardCalibration(
    channels: [
      for (int i = 0; i < channels; ++i)
        ChannelBoardCalibration(nominals: testNominals),
    ],
  );

  /// Nominal ladder values (test input; the model no longer substitutes
  /// them for missing hardware characterization).
  const nominalLadder = <double>[10000, 10, 10, 10, 10, 10000];

  /// The demo device's PGA readback (1x on all channels, matching cal.adc).
  const demoGains = <double>[1, 1, 1, 1];

  Int32List frameOf(int value) =>
      Int32List(channels)..fillRange(0, channels, value);

  void feed(DataHub hub, Int32List frame, int count) {
    for (int i = 0; i < count; i++) {
      hub.addSampleFrame(frame);
    }
  }

  group('peaks', () {
    test('an untouched hub reports zero peak, not sentinel garbage', () {
      final hub = DataHub();
      for (int ch = 0; ch < channels; ch++) {
        expect(hub.peakValue(ch, DisplayUnit.raw, start: 0, end: 0), 0);
      }
    });

    test('cleared events fire on clear() only, not on sample appends', () {
      final hub = DataHub();
      var cleared = 0;
      void listener(HubEvent event) {
        if (event is HubCleared) cleared++;
      }

      hub.addEventListener(listener);

      feed(hub, frameOf(7), 10);
      expect(cleared, 0);

      hub.clear();
      expect(cleared, 1);

      hub.removeEventListener(listener);
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
      expect(
        hub.peakValue(0, DisplayUnit.raw, start: 0, end: hub.totalSamples),
        -50,
      );
    });

    test('peaks are tare-adjusted at read time', () {
      final hub = DataHub();
      feed(hub, frameOf(1000), 10);
      hub.requestTare();
      feed(hub, frameOf(1000), 1024); // completes the tare at 1000
      expect(
        hub.peakValue(0, DisplayUnit.raw, start: 0, end: hub.totalSamples),
        0,
      );
    });
  });

  group('windowed peak', () {
    test('only samples inside the window count', () {
      final hub = DataHub();
      final frame = Int32List(channels);
      // 300 samples of 100 with a 9000-count spike at index 50.
      for (int i = 0; i < 300; i++) {
        frame[0] = i == 50 ? 9000 : 100;
        hub.addSampleFrame(frame);
      }
      final total = hub.totalSamples;
      expect(hub.peakValue(0, DisplayUnit.raw, start: 0, end: total), 9000);
      expect(hub.peakValue(0, DisplayUnit.raw, start: 100, end: total), 100);
      // end is exclusive: the spike at 50 falls outside [0, 50).
      expect(hub.peakValue(0, DisplayUnit.raw, start: 0, end: 50), 100);
      expect(hub.peakValue(0, DisplayUnit.raw, start: 50, end: 51), 9000);
    });

    test('bucket-misaligned windows are exact', () {
      final hub = DataHub();
      final frame = Int32List(channels);
      // Bucket size is 100: maxima at 37 (bucket 0) and 237 (bucket 2).
      for (int i = 0; i < 500; i++) {
        frame[0] = switch (i) {
          37 => 7000,
          237 => 8000,
          _ => 10,
        };
        hub.addSampleFrame(frame);
      }
      // Head scan (38..100) + folded buckets: misses the 7000 at 37.
      expect(hub.peakValue(0, DisplayUnit.raw, start: 38, end: 500), 8000);
      // Folded buckets + tail scan (200..237): misses the 8000 at 237.
      expect(hub.peakValue(0, DisplayUnit.raw, start: 0, end: 237), 7000);
    });

    test('held values inside a gap count toward the window peak', () {
      final hub = DataHub();
      feed(hub, frameOf(100), 100);
      hub.addDroppedFrames(50); // samples 100..149 held at 100
      feed(hub, frameOf(50), 100);
      // Same rule as the envelope rendering: gaps hold real stored values.
      expect(hub.peakValue(0, DisplayUnit.raw, start: 100, end: 150), 100);
      expect(hub.peakValue(0, DisplayUnit.raw, start: 150, end: 250), 50);
    });

    test('windows past the live edge clamp to the retained data', () {
      final hub = DataHub();
      feed(hub, frameOf(42), 200);
      expect(hub.peakValue(0, DisplayUnit.raw, start: 0, end: 200 + 5000), 42);
      // Entirely beyond the newest sample: no retained samples in view.
      expect(hub.peakValue(0, DisplayUnit.raw, start: 5000, end: 9999), 0);
    });

    test('windows reaching into evicted samples clamp after a ring wrap', () {
      final hub = DataHub();
      feed(hub, frameOf(1000), 1000); // evicted by the wrap below
      feed(hub, frameOf(1000), DataHub.maxDataSz - 100);
      feed(hub, frameOf(2000), 100); // live edge: samples 600900..600999
      expect(hub.totalSamples, DataHub.maxDataSz + 1000);
      expect(hub.oldestSample, 1000);

      // [0, 2000) clamps to [1000, 2000) — all 1000s. Without the clamp the
      // fold would read aliased bucket slot 9 (bucket 6009: the 2000s).
      expect(hub.peakValue(0, DisplayUnit.raw, start: 0, end: 2000), 1000);
      // The live edge and the whole retained range both see the 2000s.
      expect(
        hub.peakValue(
          0,
          DisplayUnit.raw,
          start: hub.totalSamples - 200,
          end: hub.totalSamples,
        ),
        2000,
      );
      expect(
        hub.peakValue(0, DisplayUnit.raw, start: 0, end: hub.totalSamples),
        2000,
      );
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
      expect(hub.tare[0], isNull);
      expect(hub.peakValue(0, DisplayUnit.raw, start: 0, end: 0), 0);
      expect(hub.valueBuckets[0].series.samples, 0);
      expect(hub.diffBuckets[0].series.samples, 0);

      // New data starts a fresh timeline; the old extremes are gone.
      feed(hub, frameOf(-500), 10);
      expect(hub.totalSamples, 10);
      expect(hub.rawAt(0, 0), -500);
      expect(
        hub.peakValue(0, DisplayUnit.raw, start: 0, end: hub.totalSamples),
        -500,
      );
    });

    test('aborts an in-progress tare', () {
      final hub = DataHub();
      feed(hub, frameOf(100), 10);
      hub.requestTare();
      feed(hub, frameOf(100), 10);
      expect(hub.taring, isTrue);

      hub.clear();
      expect(hub.taring, isFalse);
      expect(hub.tare[0], isNull);
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
      expect(hub.rawAt(0, 100), 500); // first tare sample is in the ring
      expect(hub.rawAt(0, 100 + 1023), 500);
      expect(hub.taring, isFalse);
      expect(hub.tare[0], 500);
      expect(hub.currentValue(0, DisplayUnit.raw), 0); // 500 - 500
    });

    test('recordings observe the samples appended during a tare', () {
      final hub = DataHub();
      final appended = <int>[];
      hub.addEventListener((event) {
        if (event is HubBatchAppended) appended.add(event.count);
      });

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
        expect(hub.rawAt(0, 110), 1000); // held value inside the gap
      },
    );

    test('a re-tare holds the old offsets until the new average lands', () {
      final hub = DataHub();
      feed(hub, frameOf(1000), 1024);
      hub.requestTare();
      feed(hub, frameOf(1000), 1024);
      expect(hub.tare[0], 1000); // established

      // Re-tare at a new level: during the window the display must NOT
      // jump to absolute (offset-inclusive) readings — the old offsets
      // stay in effect until the new average lands.
      hub.requestTare();
      feed(hub, frameOf(1500), 100);
      expect(hub.taring, isTrue);
      expect(hub.tare[0], 1000);
      expect(hub.currentValue(0, DisplayUnit.raw), 500); // 1500 - 1000

      feed(hub, frameOf(1500), 1024 - 100);
      expect(hub.taring, isFalse);
      expect(hub.tare[0], 1500);
      expect(hub.currentValue(0, DisplayUnit.raw), 0);
    });

    test('the window is one second of the configured rate', () {
      final hub = DataHub()..setSampleRate(100);
      hub.requestTare();
      feed(hub, frameOf(500), 99);
      expect(hub.taring, isTrue);
      expect(hub.tare[0], isNull);
      feed(hub, frameOf(500), 1);
      expect(hub.taring, isFalse);
      expect(hub.tare[0], 500);
    });

    test('a channel-masked tare commits only that channel', () {
      final hub = DataHub();
      final frame = Int32List(channels)
        ..[0] = 1000
        ..[1] = 2000;
      hub.requestTare(channel: 1);
      feed(hub, frame, 1000);
      expect(hub.taring, isFalse);
      expect(hub.tare[0], isNull);
      expect(hub.tare[1], 2000);
      expect(hub.currentValue(0, DisplayUnit.raw), 1000);
      expect(hub.currentValue(1, DisplayUnit.raw), 0);
    });

    test('a new tare request replaces the one in flight', () {
      final hub = DataHub();
      hub.requestTare(channel: 0);
      feed(hub, frameOf(1000), 500);
      hub.requestTare(channel: 1);
      feed(hub, frameOf(2000), 1000);
      expect(hub.taring, isFalse);
      // The replaced request never committed; its partial average is gone.
      expect(hub.tare[0], isNull);
      expect(hub.tare[1], 2000);
    });

    test('resetTare clears per channel and cancels the tare in flight', () {
      final hub = DataHub();
      hub.requestTare(channel: 0);
      feed(hub, frameOf(1000), 1000);
      hub.requestTare(channel: 1);
      feed(hub, frameOf(2000), 1000);
      expect(hub.tare[0], 1000);
      expect(hub.tare[1], 2000);

      hub.requestTare();
      feed(hub, frameOf(42), 100);
      expect(hub.taring, isTrue);

      hub.resetTare(channel: 0);
      expect(hub.taring, isFalse); // in-flight tare canceled
      expect(hub.tare[0], isNull);
      expect(hub.tare[1], 2000); // untouched

      // The canceled window must not commit later.
      feed(hub, frameOf(42), 1000);
      expect(hub.tare[0], isNull);

      hub.resetTare();
      expect(hub.tare[1], isNull);
    });

    test(
      'setTareOffset writes the offset absolutely and cancels the tare in flight',
      () {
        final hub = DataHub();
        hub.setTareOffset(1, 1234);
        expect(hub.tare[1], 1234);
        expect(hub.tare[0], isNull);

        // Absolute: replaces the offset regardless of the old value.
        hub.setTareOffset(1, -50);
        expect(hub.tare[1], -50);

        hub.requestTare(channel: 2);
        feed(hub, frameOf(1000), 500);
        expect(hub.taring, isTrue);
        hub.setTareOffset(1, 0);
        expect(hub.taring, isFalse); // canceled

        // The canceled window must not commit later.
        feed(hub, frameOf(1000), 1000);
        expect(hub.tare[2], isNull);
      },
    );

    test('tareOffset reports the amount zeroed out in the unit', () {
      final hub = DataHub()..updateBoardCalibration(nominalBoard());
      expect(hub.tareOffset(0, DisplayUnit.raw), 0);
      hub.requestTare();
      feed(hub, frameOf(1000), 1000);
      expect(hub.tareOffset(0, DisplayUnit.raw), 1000);
      expect(hub.tareOffset(0, DisplayUnit.mVv), isNotNull);
      expect(hub.tareOffset(0, DisplayUnit.kgf), isNull); // no cell assigned
    });
  });

  group('calibration', () {
    test('force units are unavailable until a load cell is assigned', () {
      final hub = DataHub()..updateBoardCalibration(nominalBoard());
      feed(hub, frameOf(1000), 5);

      expect(hub.currentValue(0, DisplayUnit.kgf), isNull);
      expect(
        hub.peakValue(0, DisplayUnit.kgf, start: 0, end: hub.totalSamples),
        isNull,
      );
      expect(hub.currentDerivative(0, DisplayUnit.kgf), isNull);
      // Electrical units convert with board calibration alone.
      expect(hub.currentValue(0, DisplayUnit.mVv), isNotNull);
      expect(hub.currentDerivative(0, DisplayUnit.mVv), isNotNull);
    });

    test('no board constants at all: only raw converts', () {
      final hub = DataHub();
      feed(hub, frameOf(1000), 5);

      expect(hub.boardDataStatus, BoardDataStatus.unreadable);
      expect(hub.currentValue(0, DisplayUnit.raw), isNotNull);
      expect(hub.currentValue(0, DisplayUnit.mVv), isNull);
      expect(hub.currentValue(0, DisplayUnit.mV), isNull);
      expect(hub.currentValue(0, DisplayUnit.kgf), isNull);
    });

    test('assigning a load cell enables force units and bumps the version', () {
      final hub = DataHub()..updateBoardCalibration(nominalBoard());
      final v0 = hub.calibrationVersion;
      feed(hub, frameOf(1000), 5);

      hub.updateLoadCells([
        LoadCellProfile(capacityKg: 200, sensitivityMvV: 2),
        null,
        null,
        null,
      ]);

      expect(hub.calibrationVersion, greaterThan(v0));
      // Nominal board: kgf = (raw - tare) / countsPerMvV * (200/2).
      expect(
        hub.currentValue(0, DisplayUnit.kgf),
        closeTo(1000 / testNominals.countsPerMvV * 100, 1e-12),
      );
      expect(hub.currentValue(1, DisplayUnit.kgf), isNull); // unassigned
    });

    test('board calibration replaces the nominal chain and bumps version', () {
      final hub = DataHub();
      final v0 = hub.calibrationVersion;
      // Every channel measures at half the nominal span (calibration is
      // board-uniform — a mixed calibrated/nominal board is invalid flash).
      final sp = ladderSetpointsMvV(nominalLadder);
      final board = BoardCalibration(
        channels: [
          for (int i = 0; i < channels; ++i)
            ChannelBoardCalibration(
              resistors: nominalLadder,
              readings: [
                for (final d in sp) 500 + 0.5 * testNominals.countsPerMvV * d,
              ],
              nominals: testNominals,
            ),
        ],
      );

      hub.updateBoardCalibration(board);
      expect(hub.calibrationVersion, greaterThan(v0));

      feed(hub, frameOf(1000), 5);
      for (final ch in [0, 1]) {
        // With no tare set, the reading is gross: anchored at the map's own
        // zero setpoint (raw 500 here), NOT at zero counts.
        expect(
          hub.currentValue(ch, DisplayUnit.mVv),
          closeTo(500 / (0.5 * testNominals.countsPerMvV), 1e-12),
        );
      }
    });

    test('derivative scales the converted difference per second', () {
      final hub = DataHub();
      expect(hub.currentDerivative(0, DisplayUnit.raw), 0); // < 2 samples
      feed(hub, frameOf(0), 1);
      hub.addSampleFrame(frameOf(1000));
      expect(
        hub.currentDerivative(0, DisplayUnit.raw),
        1000.0 * hub.sampleRateHz,
      );
    });

    test('empty flash replaces a nominals-only board', () {
      final hub = DataHub()..updateBoardCalibration(nominalBoard());
      feed(hub, frameOf(1000), 5);
      expect(hub.currentValue(0, DisplayUnit.mVv), isNotNull);
      final v1 = hub.calibrationVersion;

      hub.updateBoardCalibration(
        BoardCalibration(
          channels: [
            for (int i = 0; i < channels; ++i) ChannelBoardCalibration(),
          ],
          constantsStatus: BoardDataStatus.unprovisioned,
        ),
      );
      expect(hub.calibrationVersion, greaterThan(v1));
      expect(hub.boardDataStatus, BoardDataStatus.unprovisioned);
      expect(hub.calibrationFor(0).board.nominals, isNull);
      expect(hub.currentValue(0, DisplayUnit.mVv), isNull);
    });

    test('clearing the board calibration degrades to raw counts', () {
      final hub = DataHub()..updateBoardCalibration(nominalBoard());
      feed(hub, frameOf(1000), 5);
      expect(hub.currentValue(0, DisplayUnit.mVv), isNotNull);
      final v1 = hub.calibrationVersion;

      hub.clearBoardCalibration();
      expect(hub.calibrationVersion, greaterThan(v1));
      expect(hub.boardDataStatus, BoardDataStatus.unreadable);
      expect(hub.calibrationFor(0).board.nominals, isNull);
      expect(hub.currentValue(0, DisplayUnit.mVv), isNull);

      // A repeat clear is a no-op: no spurious cache invalidation.
      final v2 = hub.calibrationVersion;
      hub.clearBoardCalibration();
      expect(hub.calibrationVersion, v2);
    });

    test('unit availability reflects the board constants and the rig', () {
      final hub = DataHub();
      final cell = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2);
      expect(resolveUnitAvailability(hub.calibrationFor, [0, 1]), (
        boardHasNominals: false,
        anyActiveHasLoadCell: false,
      ));

      hub.updateBoardCalibration(nominalBoard());
      expect(resolveUnitAvailability(hub.calibrationFor, [0, 1]), (
        boardHasNominals: true,
        anyActiveHasLoadCell: false,
      ));

      // A cell counts only while its channel is among the shown ones.
      hub.updateLoadCells([cell, null, null, null]);
      expect(resolveUnitAvailability(hub.calibrationFor, [0]), (
        boardHasNominals: true,
        anyActiveHasLoadCell: true,
      ));
      expect(resolveUnitAvailability(hub.calibrationFor, [1]), (
        boardHasNominals: true,
        anyActiveHasLoadCell: false,
      ));
    });

    test('content-equal board calibration does not bump the version', () {
      final hub = DataHub();
      hub.updateBoardCalibration(
        BoardCalibration.parse(demoBoardCalibrationDoc, pgaGains: demoGains),
      );
      final v1 = hub.calibrationVersion;

      // A reconnect re-reading the identical document (new instances, same
      // content) must not invalidate the graph caches.
      hub.updateBoardCalibration(
        BoardCalibration.parse(demoBoardCalibrationDoc, pgaGains: demoGains),
      );
      expect(hub.calibrationVersion, v1);

      // A genuinely changed document bumps the version again.
      hub.updateBoardCalibration(
        BoardCalibration.parse(
          demoBoardCalibrationDoc.replaceFirst(
            'ch0.raw=6386310.2',
            'ch0.raw=6386310.3',
          ),
          pgaGains: demoGains,
        ),
      );
      expect(hub.calibrationVersion, greaterThan(v1));
    });

    test('content-equal load cell updates do not bump the version', () {
      final hub = DataHub();
      final cell = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2);
      hub.updateLoadCells([cell, null, null, null]);
      final v1 = hub.calibrationVersion;

      // Same content, new instances: an unrelated notify must not invalidate
      // the graph caches.
      hub.updateLoadCells([
        LoadCellProfile(capacityKg: 200, sensitivityMvV: 2),
        null,
        null,
        null,
      ]);
      expect(hub.calibrationVersion, v1);

      // A changed profile (new instance) bumps the version.
      hub.updateLoadCells([
        LoadCellProfile(capacityKg: 200, sensitivityMvV: 2.02),
        null,
        null,
        null,
      ]);
      expect(hub.calibrationVersion, greaterThan(v1));
    });
  });
}
