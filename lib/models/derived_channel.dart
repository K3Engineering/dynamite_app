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
