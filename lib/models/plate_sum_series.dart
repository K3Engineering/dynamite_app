import 'dart:math' as math;
import 'dart:typed_data';

import 'bucket_series.dart';
import 'channel_calibration.dart';
import 'device_profile.dart';

// ---------------------------------------------------------------------------
// Plate-sum series
//
// Ingest-time accumulation of the four-corner plate's total force, M(j) =
// Σ_c w_c · map_c(raw_c(j)) in kgf (w = cell kgfPerMvV, map = board
// mvVFromRaw). This is what makes the top-graph sum a first-class bucketed
// series: per-channel buckets can never compose into a sum's (min of a sum
// ≠ sum of mins — see [EnvelopeSeries]), but an accumulated M buckets like
// any hardware channel.
//
// Why M factorizes exactly: net_c = (map_c − tareMvV_c) · w_c · f_unit, so
// Σ net_c = f_unit · (M − Σ w_c·tareMvV_c). The display unit factor and the
// tare shift are bind-time constants, so bucket extremes AND means map
// exactly — no rebuild on tare or unit switches. A rebuild is needed only
// when maps or weights change (board calibration, cell assignment).
//
// Force display units only: mV/V/mV weight channels by 1.0 rather than
// kgfPerMvV, and raw never sees the board map — neither is affine in M, so
// those units keep the exact per-sample path.
// ---------------------------------------------------------------------------

/// Fixed-point accumulator for the plate-sum series. Buckets store
/// `M / quantumKgf` quantized to int32, so the standard [BucketSeries]
/// machinery applies unchanged.
///
/// Quantum derivation: 2× the worst-case plate force — Σ weights × the map
/// extremes over the signed-24-bit raw domain — divided into 1e6 steps.
/// Realistic quantized values then stay ≤5e5 (bucket sums 4× clear of int32
/// overflow; the defensive clamp in [_quantize] covers beyond-domain
/// garbage), while the quantum sits below the summed noise floor at
/// plausible cell sensitivities. That ±quantum/2 is the ONLY divergence from
/// the exact per-sample path; it is far below a render pixel.
class PlateSumAccumulator {
  PlateSumAccumulator._(
    this._maps,
    this._weights, {
    required BucketAccumulator buckets,
    required this.quantumKgf,
  }) : _buckets = buckets;

  /// Raw values are signed 24-bit from the packet decoder.
  static const double _kRawAbsMax = 8388608; // 2^23

  /// Quantized-value clamp: keeps a bucket's 100-sample sum 4x under int32
  /// max even when fed nonsense. >25x the largest realistic value (see the
  /// class doc), so it never engages on real data.
  static const int _kQClamp = 15000000;

  /// The per-channel board maps (mvVFromRaw) and cell weights (kgfPerMvV).
  final List<double Function(double raw)> _maps;
  final List<double> _weights;
  final BucketAccumulator _buckets;

  /// Bucket quantum in kgf: buckets store `M / quantumKgf`, so a
  /// raw-to-display closure starts from `quantumKgf * bucketValue`.
  final double quantumKgf;

  /// Hold state for gap samples, seeded from the zero frame: the hub's rings
  /// initialize "current" to 0, so a hold before the first real frame is a
  /// zero frame on every channel.
  late int _lastQuantized = _quantize(weightedKgf(_zeroFrame));

  static final Int32List _zeroFrame = Int32List(kAdcChannelCount);

  /// Null when ANY channel can't express plate force (no board map or no
  /// load cell): the sum is total plate force or nothing — the exact path
  /// remains for everything else.
  static PlateSumAccumulator? tryBuild(
    List<ChannelCalibration> calibrations, {
    required int bucketSize,
    required int numBuckets,
  }) {
    if (calibrations.length < kAdcChannelCount) return null;
    final maps = <double Function(double raw)>[];
    final weights = <double>[];
    double bound = 0;
    for (int c = 0; c < kAdcChannelCount; c++) {
      final board = calibrations[c].board;
      final cell = calibrations[c].loadCell;
      if (board == null || cell == null) return null;
      maps.add(board.mvVFromRaw);
      weights.add(cell.kgfPerMvV);
      // The maps are monotone (calibration invariant), so the extreme over
      // the raw domain is at an endpoint.
      bound +=
          cell.kgfPerMvV *
          math.max(
            board.mvVFromRaw(_kRawAbsMax).abs(),
            board.mvVFromRaw(-_kRawAbsMax).abs(),
          );
    }
    return PlateSumAccumulator._(
      maps,
      weights,
      buckets: BucketAccumulator(
        bucketSize: bucketSize,
        numBuckets: numBuckets,
      ),
      quantumKgf: 2 * bound / 1e6,
    );
  }

  /// M for one sample (kgf): the cell-weighted board-map sum of its four
  /// channel values, in channel order.
  double weightedKgf(Int32List rawValues) {
    double m = 0;
    for (int c = 0; c < kAdcChannelCount; c++) {
      m += _weights[c] * _maps[c](rawValues[c].toDouble());
    }
    return m;
  }

  /// Ingest one sample's channel frame (channel order), sequentially — same
  /// contract as [BucketAccumulator.add].
  void add(int sampleIndex, Int32List rawValues) {
    _lastQuantized = _quantize(weightedKgf(rawValues));
    _buckets.add(sampleIndex, _lastQuantized);
  }

  /// A dropped sample holds the previous quantized value, mirroring the raw
  /// rings (a held frame IS the previous frame, per channel).
  void addHeld(int sampleIndex) => _buckets.add(sampleIndex, _lastQuantized);

  /// Restart ingest (new stream); aggregates are overwritten by later adds.
  void reset() {
    _buckets.reset();
    _lastQuantized = _quantize(weightedKgf(_zeroFrame));
  }

  /// Restart ingest at [startIndex] for a rebuild over a retained window of
  /// a longer stream ([BucketAccumulator.rebase] explains the slot state).
  void resetAt(int startIndex) {
    reset();
    _buckets.rebase(startIndex);
  }

  BucketSeries get series => _buckets.series;

  int get samples => _buckets.samples;

  int _quantize(double m) =>
      (m / quantumKgf).round().clamp(-_kQClamp, _kQClamp);
}
