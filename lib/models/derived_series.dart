import 'dart:math' as math;
import 'dart:typed_data';

import 'bucket_series.dart';
import 'channel_calibration.dart';
import 'derived_channel.dart';
import 'display_unit.dart';
import 'gap_list.dart';
import 'graph_data_source.dart';

// ---------------------------------------------------------------------------
// Derived-channel ingest runtime
//
// The per-source runtime of one derived channel: a per-frame evaluator over
// the hardware channels' raw frames, a quantized int32 ring + bucket
// aggregates (value AND first-difference, mirroring the hardware channels'
// ingest), and hold state for gaps and undefined-ratio samples. Because the
// derived series itself is computed per sample BEFORE bucketing, the bucket
// invariants ([EnvelopeSeries.bucketed]) hold for any weights — signed
// blends and ratios alike (the member-bucket composition that can't work,
// "min of a sum ≠ sum of mins", is never attempted).
//
// Blend (non-normalized) channels store the GROSS blend M(j) =
// Σ w_c·kgfPerMvV_c·map_c(raw_c): tare enters only as a bind-time offset in
// the display map, so a tare change never rebuilds the series (the
// factorization `PlateSumAccumulator` used for the plate sum). Normalized
// channels evaluate the ratio on NET-of-tare member values, so tare is baked
// into their samples and a tare edge requires a rebuild (the sources rescan
// the retained window, like a calibration edge).
//
// Undefined ratio samples (member sum ≤ 0 — an unloaded plate) HOLD the last
// value in the ring/buckets but are marked invalid in [valid]; exact
// evaluators report NaN there through `SampleStorage.rawValueAt`, so traces
// break instead of flatlining through unloaded spans, while bucket folds
// carry the held value (the same bias gap-held values already have).
// ---------------------------------------------------------------------------

/// Raw values are signed 24-bit from the packet decoder.
const double _kRawAbsMax = 8388608; // 2^23

/// Quantized-value clamp: keeps a bucket's 100-sample sum 4x under int32 max
/// even when fed nonsense; far above realistic values, so it never engages
/// on real data.
const int _kQClamp = 15000000;

/// Quantization of normalized (ratio) channels: unitless value per count.
const double _kRatioQuantum = 1e-6;

/// Per-member conversion pieces of one derived channel (see the file
/// header): the board map, the cell scale, the blend-effective weight
/// (w_c·kgfPerMvV_c), and the member's tare point on the map axis.
final class _MemberBinding {
  const _MemberBinding({
    required this.channel,
    required this.map,
    required this.kgfPerMvV,
    required this.effWeight,
    required this.tareMvV,
  });

  final int channel;
  final double Function(double raw) map;
  final double kgfPerMvV;
  final double effWeight;
  final double tareMvV;

  /// Gross kgf contribution of the member at [raw] (blend-space).
  double grossAt(double raw) => effWeight * map(raw);

  /// Net kgf of the member at [raw] (unweighted — the ratio denominator
  /// sums these over the members).
  double netKgfAt(double raw) => (map(raw) - tareMvV) * kgfPerMvV;
}

/// See the file header.
final class DerivedChannelRuntime {
  DerivedChannelRuntime._({
    required this.spec,
    required List<_MemberBinding> members,
    required List<double?> memberTares,
    required this.quantum,
    required this.grossBoundKgf,
    required int ringSize,
    required BucketAccumulator valueBuckets,
    required BucketAccumulator diffBuckets,
    required GapList gaps,
  }) : _members = members,
       _memberTares = memberTares,
       ring = Int32List(ringSize),
       valid = Uint8List(ringSize),
       _ingest = ChannelIngest(
         valueBuckets: valueBuckets,
         diffBuckets: diffBuckets,
         gaps: gaps,
       );

  /// Build the runtime, or null when any member can't express kgf (no board
  /// map or no load cell assigned): a derived channel exists whole or not
  /// at all.
  ///
  /// [memberTares] is NOT copied: blends re-read it at converter-bind time
  /// (their series is tare-free), so the live hub must pass its mutable
  /// tare list. Normalized channels bake the tare at build time instead
  /// (see the file header), so for them the list is consumed here.
  static DerivedChannelRuntime? tryBuild(
    DerivedChannelSpec spec,
    List<ChannelCalibration> calibrations,
    List<double?> memberTares, {
    required int bucketSize,
    required int numBuckets,
    required int ringSize,
    required GapList gaps,
  }) {
    final memberIds = spec.members;
    if (memberIds.isEmpty) return null;
    final members = <_MemberBinding>[];
    for (final c in memberIds) {
      final board = calibrations[c].board;
      final cell = calibrations[c].loadCell;
      if (board == null || cell == null) return null;
      final tare = memberTares[c];
      members.add(
        _MemberBinding(
          channel: c,
          map: board.mvVFromRaw,
          kgfPerMvV: cell.kgfPerMvV,
          effWeight: spec.weights[c] * cell.kgfPerMvV,
          tareMvV: tare == null ? 0.0 : board.mvVFromRaw(tare),
        ),
      );
    }
    // Full-scale bound for a blend: the maps are monotone (calibration
    // invariant), so the worst case over the raw domain is at an endpoint.
    // For a ratio the display span is unitless ±1; raw full scale is
    // 1/quantum.
    final double bound = spec.normalize
        ? 1.0
        : members.fold(
            0,
            (b, m) =>
                b +
                m.effWeight.abs() *
                    math.max(
                      m.map(_kRawAbsMax).abs(),
                      m.map(-_kRawAbsMax).abs(),
                    ),
          );
    final double quantum = spec.normalize ? _kRatioQuantum : 2 * bound / 1e6;
    return DerivedChannelRuntime._(
      spec: spec,
      members: members,
      memberTares: memberTares,
      quantum: quantum,
      grossBoundKgf: bound,
      ringSize: ringSize,
      valueBuckets: BucketAccumulator(
        bucketSize: bucketSize,
        numBuckets: numBuckets,
      ),
      diffBuckets: BucketAccumulator(
        bucketSize: bucketSize,
        numBuckets: numBuckets,
      ),
      gaps: gaps,
    );
  }

  final DerivedChannelSpec spec;

  final List<_MemberBinding> _members;
  final List<double?> _memberTares;

  /// Ring value quantum: kgf per count for blends, unitless per count for
  /// ratios.
  final double quantum;

  /// Blend full scale in kgf (see [SeriesConverter.fullScaleRaw]); 1.0 for
  /// ratios (their display span is a fraction).
  final double grossBoundKgf;

  /// Quantized values, ring-addressed like the hardware rings.
  final Int32List ring;

  /// Per-sample validity: false where a ratio was undefined (member sum ≤
  /// 0) and the ring holds the previous value. Gap samples stay VALID —
  /// their held value is missing-data, tracked in the source's gaps.
  final Uint8List valid;

  final ChannelIngest _ingest;

  int _prevQuantized = 0;
  int _held = 0;

  /// The channel's value for one frame, in kgf (blend) or unitless (ratio);
  /// null for an undefined ratio (member sum ≤ 0).
  double? _evaluate(Int32List raws) {
    if (!spec.normalize) {
      double m = 0;
      for (final b in _members) {
        m += b.grossAt(raws[b.channel].toDouble());
      }
      return m;
    }
    double numerator = 0, denominator = 0;
    for (final b in _members) {
      final raw = raws[b.channel].toDouble();
      numerator += spec.weights[b.channel] * b.netKgfAt(raw);
      denominator += b.netKgfAt(raw);
    }
    if (!(denominator > 0)) return null;
    return numerator / denominator;
  }

  /// Ingest one frame of hardware raw values (channel order), sequentially —
  /// same contract as [BucketAccumulator.add].
  void addFrame(int sampleIndex, Int32List raws) {
    final v = _evaluate(raws);
    if (v == null) {
      valid[sampleIndex % ring.length] = 0;
      _write(sampleIndex, _held);
      return;
    }
    valid[sampleIndex % ring.length] = 1;
    _held = _quantize(v);
    _write(sampleIndex, _held);
  }

  /// A dropped sample holds the previous quantized value, mirroring the raw
  /// rings, and stays valid (gap-ness is the source's gaps list).
  void addHeld(int sampleIndex) {
    valid[sampleIndex % ring.length] = 1;
    _write(sampleIndex, _held);
  }

  void _write(int sampleIndex, int qv) {
    ring[sampleIndex % ring.length] = qv;
    _ingest.add(sampleIndex, qv, _prevQuantized);
    _prevQuantized = qv;
  }

  /// Restart ingest (new stream); aggregates are overwritten by later adds.
  void reset() {
    _ingest.reset();
    _prevQuantized = 0;
    _held = 0;
  }

  /// Restart ingest at [startIndex] for a rebuild over a retained window.
  void resetAt(int startIndex) {
    reset();
    _ingest.valueBuckets.rebase(startIndex);
    _ingest.diffBuckets.rebase(startIndex);
  }

  BucketSeries get valueSeries => _ingest.valueBuckets.series;
  BucketSeries get diffSeries => _ingest.diffBuckets.series;
  (int, int)? get extremes => _ingest.extremes;

  bool validAt(int sampleIndex) => valid[sampleIndex % ring.length] != 0;

  /// The blend's kgf at the current member tares — the bind-time offset of
  /// the display map; re-evaluated per bind so blend series never rebuild
  /// on tare. Zero (and unused) for ratios.
  double tareOffsetKgf() {
    double t = 0;
    for (final b in _members) {
      final tare = _memberTares[b.channel];
      if (tare != null) t += b.effWeight * b.map(tare);
    }
    return t;
  }

  int _quantize(double v) => (v / quantum).round().clamp(-_kQClamp, _kQClamp);

  /// The display converter over this channel's raw (ring) space.
  SeriesConverter converterFor() => _DerivedSeriesConverter(this);
}

/// Display conversion of a derived channel's stored (ring) values: blends
/// are kgf series convertible to force units only, ratios are unitless
/// (any unit, identity). See [DerivedChannelRuntime].
final class _DerivedSeriesConverter implements SeriesConverter {
  const _DerivedSeriesConverter(this._runtime);

  final DerivedChannelRuntime _runtime;

  @override
  bool get unitless => _runtime.spec.normalize;

  @override
  double get fullScaleRaw => _runtime.grossBoundKgf / _runtime.quantum;

  @override
  double Function(double raw)? netMap(DisplayUnit unit) {
    final quantum = _runtime.quantum;
    if (unitless) return (v) => v * quantum;
    final factor = unit.kgfFactor;
    if (factor == null) return null;
    final offset = _runtime.tareOffsetKgf();
    return (v) => (v * quantum - offset) * factor;
  }

  @override
  double Function(double rawDiff)? diffMap(DisplayUnit unit) {
    final quantum = _runtime.quantum;
    if (unitless) return (d) => d * quantum;
    final factor = unit.kgfFactor;
    if (factor == null) return null;
    return (d) => d * quantum * factor;
  }
}
