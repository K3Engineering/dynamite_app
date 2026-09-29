import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/board_calibration.dart';
import 'package:dynamite_app/models/bucket_series.dart';
import 'package:dynamite_app/models/channel_calibration.dart';
import 'package:dynamite_app/models/derived_channel.dart';
import 'package:dynamite_app/models/derived_series.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/models/gap_list.dart';
import 'package:dynamite_app/models/load_cell.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/session_data.dart';

/// Tests for [DerivedChannelRuntime]: the ingest-time derived-channel series
/// (blends and ratios) behind every view of a derived channel. The
/// load-bearing invariants: a channel exists whole or not at all (any member
/// without board map or cell kills it), buckets track the quantized derived
/// series (gap samples hold, like the raw rings), a rebuild can rebase onto
/// a wrapped ring, and undefined ratio samples hold but read as invalid.
void main() {
  // Nominal-only fixture: mvVFromRaw is linear (raw / countsPerMvV), so the
  // expected blend values are closed-form.
  const testNominals = ChannelNominals(
    adcFsrV: 1.2,
    afeGain: 101,
    pgaGain: 1,
    excitationV: 4.53,
  );
  const cell = LoadCellProfile(capacityKg: 200, sensitivityMvV: 2);
  const board = NominalChannelBoard(testNominals);

  // The plate basis over identity corner order; [0] is Σ, [1] the X ratio.
  final specs = forcePlateChannels(const [0, 1, 2, 3]);
  final sumSpec = specs[0];
  final xSpec = specs[1];

  List<ChannelCalibration> fullCal({bool withCell = true}) => [
    for (int i = 0; i < kAdcChannelCount; i++)
      ChannelCalibration(board: board, loadCell: withCell ? cell : null),
  ];

  DerivedChannelRuntime buildRt(
    DerivedChannelSpec spec, {
    int numBuckets = 8,
    List<double?>? tares,
  }) => DerivedChannelRuntime.tryBuild(
    spec,
    fullCal(),
    tares ?? List.filled(kAdcChannelCount, null),
    bucketSize: kBucketSize,
    numBuckets: numBuckets,
    ringSize: 100000,
    gaps: GapList(),
  )!;

  /// Expected Σ (kgf, gross) of a frame under the linear fixture.
  double expectedSumKgf(Int32List frame) {
    final cpmv = testNominals.countsPerMvV;
    double m = 0;
    for (int c = 0; c < kAdcChannelCount; c++) {
      m += cell.kgfPerMvV * frame[c] / cpmv;
    }
    return m;
  }

  group('tryBuild', () {
    test('null when any member lacks a load cell or the board map', () {
      expect(
        DerivedChannelRuntime.tryBuild(
          sumSpec,
          [
            for (int i = 0; i < kAdcChannelCount; i++)
              ChannelCalibration(board: board, loadCell: i == 2 ? null : cell),
          ],
          List.filled(kAdcChannelCount, null),
          bucketSize: kBucketSize,
          numBuckets: 8,
          ringSize: 1000,
          gaps: GapList(),
        ),
        isNull,
      );
      expect(
        DerivedChannelRuntime.tryBuild(
          sumSpec,
          [
            for (int i = 0; i < kAdcChannelCount; i++)
              const ChannelCalibration(board: null, loadCell: cell),
          ],
          List.filled(kAdcChannelCount, null),
          bucketSize: kBucketSize,
          numBuckets: 8,
          ringSize: 1000,
          gaps: GapList(),
        ),
        isNull,
      );
    });
  });

  group('blend ingest', () {
    test('buckets track the quantized blend of each frame', () {
      final rt = buildRt(sumSpec);
      final frame = Int32List.fromList([1000, -500, 2000, 300]);
      const n = kBucketSize; // exactly one full bucket
      for (int i = 0; i < n; i++) {
        rt.addFrame(i, frame);
      }
      final expected = (expectedSumKgf(frame) / rt.quantum).round();
      final buckets = rt.valueSeries;
      expect(buckets.samples, n);
      expect(buckets.mins[0], expected);
      expect(buckets.maxs[0], expected);
      expect(buckets.sums[0], expected * n);
    });

    test('dropped samples hold the previous quantized value', () {
      final rt = buildRt(sumSpec);
      rt.addFrame(0, Int32List.fromList([1000, 1000, 1000, 1000]));
      final held = rt.valueSeries.mins[0];
      rt.addHeld(1);
      rt.addHeld(2);
      expect(rt.valueSeries.mins[0], held);
      expect(rt.valueSeries.maxs[0], held);
      expect(rt.valueSeries.sums[0], held * 3);
      // A held run before ANY real frame holds the initial zero, mirroring
      // the hub rings' zero-initialized "current".
      final cold = buildRt(sumSpec);
      cold.addHeld(0);
      cold.addHeld(1);
      expect(cold.valueSeries.mins[0], 0);
    });

    test('resetAt rebases onto a wrapped ring (absolute indexing)', () {
      final rt = buildRt(sumSpec);
      rt.resetAt(5000);
      final frame = Int32List.fromList([7, 7, 7, 7]);
      for (int i = 5000; i < 5000 + kBucketSize; i++) {
        rt.addFrame(i, frame);
      }
      // Absolute addressing: bucket 50 (5000 ~/ 100) holds this frame.
      final b = rt.valueSeries;
      expect(b.samples, 5000 + kBucketSize);
      expect(b.mins[50 % 8], (expectedSumKgf(frame) / rt.quantum).round());
    });

    test('diff buckets skip gap edges, like the hardware ingest', () {
      final gaps = GapList();
      final rt = DerivedChannelRuntime.tryBuild(
        sumSpec,
        fullCal(),
        List.filled(kAdcChannelCount, null),
        bucketSize: kBucketSize,
        numBuckets: 8,
        ringSize: 100000,
        gaps: gaps,
      )!;
      rt.addFrame(0, Int32List.fromList([0, 0, 0, 0]));
      rt.addFrame(1, Int32List.fromList([100, 100, 100, 100]));
      // Samples 2..4 are a gap: holds, zero diffs.
      gaps.append(2, 5);
      rt.addHeld(2);
      rt.addHeld(3);
      rt.addHeld(4);
      rt.addFrame(5, Int32List.fromList([300, 300, 300, 300]));
      // Diff rule: sample 0 is 0; the 1->2 step into a held run is zero
      // (held == previous); the post-gap jump at 5 is suppressed (gap edge),
      // so only the 0 -> 1 transition contributes to the bucket's diff sum.
      final expectedStep1 =
          (expectedSumKgf(Int32List.fromList([100, 100, 100, 100])) /
                  rt.quantum)
              .round();
      expect(rt.diffSeries.sums[0], expectedStep1);
    });

    test(
      'bucket extremes over a window match the true blend within one quantum',
      () {
        final rt = buildRt(sumSpec);
        final frames = <Int32List>[];
        for (int i = 0; i < 3 * kBucketSize; i++) {
          final f = Int32List.fromList([
            (5000 * math.sin(i / 7)).round(),
            (3000 * math.cos(i / 5)).round(),
            (2000 * math.sin(i / 11 + 1)).round(),
            (4000 * math.cos(i / 3 + 2)).round(),
          ]);
          frames.add(f);
          rt.addFrame(i, f);
        }
        // The exact fold the renderers use (bucket fast path + exact edges).
        final ext = windowedExtremes(
          rt.valueSeries,
          10,
          3 * kBucketSize - 10,
          (j) => rt.ring[j % rt.ring.length].toDouble(),
        )!;
        double trueMin = double.infinity, trueMax = double.negativeInfinity;
        for (int j = 10; j < 3 * kBucketSize - 10; j++) {
          final m = expectedSumKgf(frames[j]);
          trueMin = math.min(trueMin, m);
          trueMax = math.max(trueMax, m);
        }
        final half = rt.quantum / 2 + 1e-12;
        expect(ext.$1 * rt.quantum, closeTo(trueMin, half));
        expect(ext.$2 * rt.quantum, closeTo(trueMax, half));
      },
    );
  });

  group('ratio ingest', () {
    test(
      'the ratio is blend over member sum; undefined holds + invalidates',
      () {
        final rt = buildRt(xSpec);
        // Load only on channel 0 (a −1 weight): ratio −1.
        rt.addFrame(0, Int32List.fromList([1000, 0, 0, 0]));
        expect(rt.ring[0], -1000000);
        // Load only on channel 1 (+1): ratio +1.
        rt.addFrame(1, Int32List.fromList([0, 1000, 0, 0]));
        expect(rt.ring[1], 1000000);
        // Equal members: the X blend is zeroed by symmetry.
        rt.addFrame(2, Int32List.fromList([1000, 1000, 1000, 1000]));
        expect(rt.ring[2], 0);
        // No positive member sum: undefined — holds the previous value and
        // reads invalid.
        rt.addFrame(3, Int32List.fromList([0, 0, 0, 0]));
        expect(rt.ring[3], 0);
        expect(rt.validAt(3), isFalse);
        expect(rt.validAt(2), isTrue);
      },
    );
  });

  group('DataHub wiring', () {
    DataHub hubWithCal({bool cells = true}) {
      final hub = DataHub()
        ..updateDerivedChannels(specs)
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

    test('derived channels need board map and cells on every member', () {
      expect(
        DataHub().seriesConverterFor(kAdcChannelCount).netMap(DisplayUnit.kgf),
        isNull,
      );
      expect(hubWithCal(cells: false).channelCount, 8);
      expect(
        hubWithCal(
          cells: false,
        ).seriesConverterFor(kAdcChannelCount).netMap(DisplayUnit.kgf),
        isNull,
      );
      expect(
        hubWithCal()
            .seriesConverterFor(kAdcChannelCount)
            .netMap(DisplayUnit.kgf),
        isNotNull,
      );
    });

    test('frames and drops accumulate; a cell change rebuilds in place', () {
      final hub = hubWithCal();
      final frame = Int32List.fromList([100, 100, 100, 100]);
      for (int i = 0; i < 250; i++) {
        hub.addSampleFrame(frame);
      }
      hub.addDroppedFrames(10);
      expect(hub.valueBucketsFor(4).samples, 260);
      // Rebuild on cell assignment: rescans the retained window, same length.
      hub.updateLoadCells([
        for (int i = 0; i < kAdcChannelCount; i++)
          const LoadCellProfile(capacityKg: 100, sensitivityMvV: 2),
      ]);
      expect(hub.valueBucketsFor(4).samples, 260);
      // Losing a cell kills the blend; the channel reports unavailable.
      hub.updateLoadCells([for (int i = 0; i < kAdcChannelCount; i++) null]);
      expect(hub.seriesConverterFor(4).netMap(DisplayUnit.kgf), isNull);
    });

    test('tare leaves blend storage untouched (bind-time shift)', () {
      final hub = hubWithCal();
      final frame = Int32List.fromList([100, 100, 100, 100]);
      for (int i = 0; i < 20; i++) {
        hub.addSampleFrame(frame);
      }
      final before = [for (int j = 0; j < 20; j++) hub.rawAt(4, j)];
      hub.setTareOffset(0, 100);
      expect([for (int j = 0; j < 20; j++) hub.rawAt(4, j)], before);
      expect(hub.valueBucketsFor(4).samples, 20);
    });

    test('clear restarts ingest', () {
      final hub = hubWithCal();
      final frame = Int32List.fromList([100, 100, 100, 100]);
      for (int i = 0; i < 20; i++) {
        hub.addSampleFrame(frame);
      }
      hub.clear();
      hub.addSampleFrame(frame);
      expect(hub.valueBucketsFor(4).samples, 1);
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
      derivedSpecs: specs,
    );

    test('replayed at load when every member converts to force', () {
      expect(session().valueBucketsFor(4).samples, 250);
      expect(
        session(cells: false).seriesConverterFor(4).netMap(DisplayUnit.kgf),
        isNull,
      );
    });
  });
}
