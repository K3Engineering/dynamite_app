import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/bucket_series.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/models/plate_sum_series.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/session_data.dart';

/// Tests for [PlateSumAccumulator]: the ingest-time plate-force series behind
/// the top-graph sum's bucket fast path. The load-bearing invariants: the
/// series is total-force-or-nothing (any channel without board map or cell
/// kills it), buckets track the quantized weighted sum (gap samples hold,
/// like the raw rings), and a rebuild can rebase onto a wrapped ring.
void main() {
  // Nominal-only fixture: mvVFromRaw is linear (raw / countsPerMvV), so the
  // expected weighted sums are closed-form.
  const testNominals = ChannelNominals(
    adcFsrV: 1.2,
    afeGain: 101,
    pgaGain: 1,
    excitationV: 4.53,
  );
  const cell = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2);
  const board = NominalChannelBoard(testNominals);

  List<ChannelCalibration> fullCal({bool withCell = true}) => [
    for (int i = 0; i < kAdcChannelCount; i++)
      ChannelCalibration(board: board, loadCell: withCell ? cell : null),
  ];

  PlateSumAccumulator buildAcc({int numBuckets = 8}) =>
      PlateSumAccumulator.tryBuild(
        fullCal(),
        bucketSize: kBucketSize,
        numBuckets: numBuckets,
      )!;

  /// Expected M (kgf) of a frame under the linear fixture, from first
  /// principles (not through the accumulator).
  double expectedKgf(Int32List frame) {
    final cpmv = testNominals.countsPerMvV;
    double m = 0;
    for (int c = 0; c < kAdcChannelCount; c++) {
      m += cell.kgfPerMvV * frame[c] / cpmv;
    }
    return m;
  }

  group('tryBuild', () {
    test('null when any channel lacks a load cell or the board map', () {
      expect(
        PlateSumAccumulator.tryBuild(
          [
            for (int i = 0; i < kAdcChannelCount; i++)
              ChannelCalibration(board: board, loadCell: i == 2 ? null : cell),
          ],
          bucketSize: kBucketSize,
          numBuckets: 8,
        ),
        isNull,
      );
      expect(
        PlateSumAccumulator.tryBuild(
          [
            for (int i = 0; i < kAdcChannelCount; i++)
              const ChannelCalibration(board: null, loadCell: cell),
          ],
          bucketSize: kBucketSize,
          numBuckets: 8,
        ),
        isNull,
      );
    });

    test('null for a short channel list', () {
      expect(
        PlateSumAccumulator.tryBuild(
          fullCal().sublist(0, 2),
          bucketSize: kBucketSize,
          numBuckets: 8,
        ),
        isNull,
      );
    });
  });

  group('ingest', () {
    test('buckets track the quantized weighted sum of each frame', () {
      final acc = buildAcc();
      final frame = Int32List.fromList([1000, -500, 2000, 300]);
      const n = kBucketSize; // exactly one full bucket
      for (int i = 0; i < n; i++) {
        acc.add(i, frame);
      }
      final expected = (expectedKgf(frame) / acc.quantumKgf).round();
      final buckets = acc.series;
      expect(buckets.samples, n);
      expect(buckets.mins[0], expected);
      expect(buckets.maxs[0], expected);
      expect(buckets.sums[0], expected * n);
      // Per-sample quantization error of weightedKgf is by construction.
      expect(acc.weightedKgf(frame), closeTo(expectedKgf(frame), 1e-9));
    });

    test('dropped samples hold the previous quantized value', () {
      final acc = buildAcc();
      acc.add(0, Int32List.fromList([1000, 1000, 1000, 1000]));
      final held = acc.series.mins[0];
      acc.addHeld(1);
      acc.addHeld(2);
      expect(acc.series.mins[0], held);
      expect(acc.series.maxs[0], held);
      expect(acc.series.sums[0], held * 3);
      // A held run before ANY real frame is the zero frame, mirroring the
      // hub rings' zero-initialized "current": linear map → zero sum.
      final cold = buildAcc();
      cold.addHeld(0);
      cold.addHeld(1);
      expect(cold.series.mins[0], 0);
    });

    test('resetAt rebases onto a wrapped ring (absolute indexing)', () {
      final acc = buildAcc();
      acc.resetAt(5000);
      final frame = Int32List.fromList([7, 7, 7, 7]);
      for (int i = 5000; i < 5000 + kBucketSize; i++) {
        acc.add(i, frame);
      }
      expect(acc.samples, 5000 + kBucketSize);
      // Absolute addressing: bucket 50 (5000 ~/ 100) holds this frame.
      final b = acc.series;
      expect(b.mins[50 % 8], (expectedKgf(frame) / acc.quantumKgf).round());
    });

    test(
      'bucket extremes over a window match the true sum within one quantum',
      () {
        final acc = buildAcc();
        final frames = <Int32List>[];
        for (int i = 0; i < 3 * kBucketSize; i++) {
          final f = Int32List.fromList([
            (5000 * math.sin(i / 7)).round(),
            (3000 * math.cos(i / 5)).round(),
            (2000 * math.sin(i / 11 + 1)).round(),
            (4000 * math.cos(i / 3 + 2)).round(),
          ]);
          frames.add(f);
          acc.add(i, f);
        }
        // The exact fold the renderers use (bucket fast path + exact edges).
        final ext = windowedExtremes(
          acc.series,
          10,
          3 * kBucketSize - 10,
          (j) => acc.weightedKgf(frames[j]) / acc.quantumKgf,
        )!;
        double trueMin = double.infinity, trueMax = double.negativeInfinity;
        for (int j = 10; j < 3 * kBucketSize - 10; j++) {
          final m = expectedKgf(frames[j]);
          trueMin = math.min(trueMin, m);
          trueMax = math.max(trueMax, m);
        }
        final half = acc.quantumKgf / 2 + 1e-12;
        expect(ext.$1 * acc.quantumKgf, closeTo(trueMin, half));
        expect(ext.$2 * acc.quantumKgf, closeTo(trueMax, half));
      },
    );
  });

  group('DataHub wiring', () {
    DataHub hubWithCal({bool cells = true}) {
      final hub = DataHub()
        ..updateBoardCalibration(
          ProvisionedBoardCalibration(
            nominals: BoardNominals(
              adcFsrV: 1.2,
              afeGain: 101,
              excitationV: 4.53,
              pgaGains: const [1, 1, 1, 1],
            ),
          ),
        );
      if (cells) {
        hub.updateLoadCells([for (int i = 0; i < kAdcChannelCount; i++) cell]);
      }
      return hub;
    }

    test('plateSum needs both a board map and cells on every channel', () {
      expect(DataHub().plateSum, isNull);
      expect(hubWithCal(cells: false).plateSum, isNull);
      expect(hubWithCal().plateSum, isNotNull);
    });

    test('frames and drops accumulate; a cell change rebuilds in place', () {
      final hub = hubWithCal();
      final frame = Int32List.fromList([100, 100, 100, 100]);
      for (int i = 0; i < 250; i++) {
        hub.addSampleFrame(frame);
      }
      hub.addDroppedFrames(10);
      expect(hub.plateSum!.samples, 260);
      // Rebuild on cell assignment: rescans the retained window, same length.
      hub.updateLoadCells([
        for (int i = 0; i < kAdcChannelCount; i++)
          const LoadCellProfile(capacityKg: 100, sensitivityMvV: 2),
      ]);
      expect(hub.plateSum!.samples, 260);
      // Losing a cell kills the series; the exact path remains for panes.
      hub.updateLoadCells([for (int i = 0; i < kAdcChannelCount; i++) null]);
      expect(hub.plateSum, isNull);
    });

    test('tare changes do not touch the series (bind-time shift)', () {
      final hub = hubWithCal();
      final frame = Int32List.fromList([100, 100, 100, 100]);
      for (int i = 0; i < 20; i++) {
        hub.addSampleFrame(frame);
      }
      final before = hub.plateSum!;
      hub.setTareOffset(0, 100);
      expect(identical(hub.plateSum, before), isTrue);
      expect(hub.plateSum!.samples, 20);
    });

    test('clear restarts ingest', () {
      final hub = hubWithCal();
      final frame = Int32List.fromList([100, 100, 100, 100]);
      for (int i = 0; i < 20; i++) {
        hub.addSampleFrame(frame);
      }
      hub.clear();
      hub.addSampleFrame(frame);
      expect(hub.plateSum!.samples, 1);
    });
  });

  group('SessionData wiring', () {
    SessionData session({bool cells = true, int n = 250}) => SessionData(
      channels: [
        for (int c = 0; c < kAdcChannelCount; c++)
          Int32List.fromList([for (int i = 0; i < n; i++) 100 + c + i]),
      ],
      sampleRate: 1000,
      sampleCount: n,
      calibrations: fullCal(withCell: cells),
      tares: List.filled(kAdcChannelCount, null),
      ssnOrigin: 0,
    );

    test('built at load when every channel converts to force', () {
      expect(session().plateSum!.samples, 250);
      expect(session(cells: false).plateSum, isNull);
    });
  });
}
