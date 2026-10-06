import 'device_profile.dart';

// ---------------------------------------------------------------------------
// Derived channels
//
// A derived channel is a weighted blend of hardware channels over their
// net-kgf values (board map + load cell, net of tare), optionally NORMALIZED
// by the members' straight sum. That closed algebra — blend or ratio of
// blend over member sum — covers the real rig math (plate CoP axes, thrust
// sums/differences, torsion) without an expression system.
//
// Channel id space: 0..kAdcChannelCount-1 are hardware channels, ids
// kAdcChannelCount.. are derived channels in config order. Derived storage,
// aggregates, and conversion all key off this id space (see
// `graph_data_source.dart`).
// ---------------------------------------------------------------------------

/// Max derived channels per rig: a full-rank remix of the four hardware
/// channels (e.g. the force plate's sum, X, Y, error basis).
const int kMaxDerivedChannels = 4;

/// Total addressable channel ids.
const int kMaxChannelCount = kAdcChannelCount + kMaxDerivedChannels;

/// Whether [id] addresses a derived channel (see the file header).
bool isDerivedChannelId(int id) => id >= kAdcChannelCount;

/// Index of a derived channel id into the config list.
int derivedIndexOf(int id) => id - kAdcChannelCount;

/// One derived channel: [weights] per hardware channel (0 = not a member);
/// when [normalize] the blend is divided by the members' straight sum (CoP
/// coordinates, load share), making the channel unitless.
final class DerivedChannelSpec {
  const DerivedChannelSpec({
    required this.label,
    required this.weights,
    required this.normalize,
  }) : assert(weights.length == kAdcChannelCount);

  /// Minted from the weight vector (see [forcePlateChannels]); recomputed
  /// on reweight rather than stored, so the two can never desync.
  final String label;

  /// Blend weight per hardware channel, index-aligned.
  final List<double> weights;

  /// Divide the blend by the members' straight sum.
  final bool normalize;

  /// Hardware channels with a nonzero weight.
  List<int> get members => [
    for (int c = 0; c < kAdcChannelCount; c++)
      if (weights[c] != 0) c,
  ];
}

/// The rig's math-channel profile: which derived channels exist and how the
/// UI uses them (the plate axes, the plate error channel). `none` is a
/// generic 4-channel rig: no derived ids at all.
///
/// Owned app-side for now (see `derived_channels.dart`); sessions snapshot
/// it at record start via [toJson]/[fromJson] so review renders with the
/// rig setup that recorded it.
final class MathProfile {
  MathProfile.none()
    : specs = const [],
      plateXId = null,
      plateYId = null,
      plateErrId = null;

  MathProfile.forcePlate(List<int> corners)
    : assert(
        corners.length == kAdcChannelCount &&
            corners.toSet().length == kAdcChannelCount,
        'corners must be a permutation of the hardware channels',
      ),
      specs = forcePlateChannels(corners),
      plateXId = kAdcChannelCount + 1,
      plateYId = kAdcChannelCount + 2,
      plateErrId = kAdcChannelCount + 3;

  /// The derived channels in id order; empty for a `none` profile.
  final List<DerivedChannelSpec> specs;

  /// The plate pane's axis/error channel ids; null when the profile has no
  /// plate semantics (not just unbound — not configured).
  final int? plateXId;
  final int? plateYId;
  final int? plateErrId;

  /// The plate corner order [TL, TR, BL, BR] of hardware channel ids (the
  /// profile's only parameter); null for a `none` profile.
  List<int>? get plateCorners =>
      plateXId == null ? null : _cornersFromSpecs(specs);

  Map<String, Object?> toJson() => plateXId == null
      ? {'kind': 'none'}
      : {
          'kind': 'forcePlate',
          // The corner permutation is the profile's only parameter; the
          // specs are re-derived on load (single source of truth).
          'corners': plateCorners,
        };

  /// Strict inverse: anything malformed throws [FormatException] (the
  /// session journal's damaged verdict).
  factory MathProfile.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('math profile: must be an object');
    }
    final specsJson = json['kind'] == 'forcePlate' ? json['corners'] : null;
    return switch (json['kind']) {
      'none' => MathProfile.none(),
      'forcePlate' => MathProfile.forcePlate(switch (specsJson) {
        final List<dynamic> l when l.length == kAdcChannelCount => [
          for (final e in l)
            e is int && e >= 0 && e < kAdcChannelCount
                ? e
                : throw const FormatException(
                    'math profile: corners must be hardware channel ids',
                  ),
        ],
        _ => throw const FormatException(
          'math profile: forcePlate needs $kAdcChannelCount corner ids',
        ),
      }),
      final other => throw FormatException('math profile: bad kind: $other'),
    };
  }

  /// Inverse of [forcePlateChannels]' weight minting: each corner occupies
  /// a distinct (X-sign, Y-sign) cell of the plate quadrants, so the corner
  /// order reads back out of the X/Y weight vectors. Only valid on specs
  /// minted by [forcePlateChannels] — asserted, since
  /// [MathProfile.forcePlate] is the only producer.
  static List<int> _cornersFromSpecs(List<DerivedChannelSpec> specs) {
    final xs = specs[1].weights; // X: left -, right +
    final ys = specs[2].weights; // Y: bottom -, top +
    final byWeights = {
      for (int m = 0; m < kAdcChannelCount; m++) (xs[m].sign, ys[m].sign): m,
    };
    final corners = [
      byWeights[(-1.0, 1.0)]!, // TL
      byWeights[(1.0, 1.0)]!, // TR
      byWeights[(-1.0, -1.0)]!, // BL
      byWeights[(1.0, -1.0)]!, // BR
    ];
    assert(() {
      final reminted = forcePlateChannels(corners);
      for (int i = 0; i < specs.length; i++) {
        for (int m = 0; m < kAdcChannelCount; m++) {
          if (reminted[i].weights[m] != specs[i].weights[m]) return false;
        }
      }
      return true;
    }(), 'corner recovery: specs were not minted by forcePlateChannels');
    return corners;
  }
}

/// Which slice of the channel id space is on screen (the stats table and
/// the graphs). Phone-width headers fit one family; `all` suits wide
/// layouts.
enum ChannelFamily {
  all,
  hardware,
  math;

  bool includes(int id) => switch (this) {
    ChannelFamily.all => true,
    ChannelFamily.hardware => !isDerivedChannelId(id),
    ChannelFamily.math => isDerivedChannelId(id),
  };

  String get label => switch (this) {
    ChannelFamily.all => 'All',
    ChannelFamily.hardware => 'Hardware',
    ChannelFamily.math => 'Math',
  };
}

/// The four-corner force-plate basis: total force, the two CoP axes, and
/// the saddle/torsion residual, from a corner assignment [TL, TR, BL, BR]
/// (hardware channel per plate corner). The four weight vectors are
/// orthogonal: a full-rank remix of the corners, so nothing is lost.
///
/// The error channel is the saddle mode (TL + BR) − (TR + BL): on a rigid
/// plate the planar fit leaves exactly this one degree of freedom, so any
/// plate-flex/racking signal lands here.
List<DerivedChannelSpec> forcePlateChannels(List<int> corners) {
  assert(corners.length == kAdcChannelCount);
  List<double> weights(double tl, double tr, double bl, double br) {
    final ws = List<double>.filled(kAdcChannelCount, 0);
    ws[corners[0]] = tl;
    ws[corners[1]] = tr;
    ws[corners[2]] = bl;
    ws[corners[3]] = br;
    return ws;
  }

  return [
    DerivedChannelSpec(
      label: 'Σ',
      weights: weights(1, 1, 1, 1),
      normalize: false,
    ),
    DerivedChannelSpec(
      label: 'X',
      weights: weights(-1, 1, -1, 1),
      normalize: true,
    ),
    DerivedChannelSpec(
      label: 'Y',
      weights: weights(1, 1, -1, -1),
      normalize: true,
    ),
    DerivedChannelSpec(
      label: 'Err',
      weights: weights(1, -1, -1, 1),
      normalize: true,
    ),
  ];
}
