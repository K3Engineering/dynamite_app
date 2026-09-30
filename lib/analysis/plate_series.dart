import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../models/channel_converter.dart';
import '../models/device_profile.dart';
import '../models/display_unit.dart';
import '../models/graph_data_source.dart';

// ---------------------------------------------------------------------------
// Plate geometry, per-sample plate reader, and captured windows
//
// The analysis core's substrate: turn a data source's four raw channels into
// kgf force and plate-normalized CoP, then capture a window of that as flat
// arrays for segmentation and metrics. Raw ADC counts (not the gap-aware
// `rawValueAt`) are read on purpose: the storage holds the previous sample
// across a gap, so held values keep the series continuous where a dropped
// packet would otherwise punch a hole through a jump.
// ---------------------------------------------------------------------------

/// Physical geometry of the plate, in millimetres. Two distinct rectangles:
/// [support*] is the four ground contact points — the frame CoP is
/// reconstructed in, since those are the only external vertical supports; the
/// plate mounts cancel out of the whole-body moment balance. [footprint*] is
/// the top surface, for drawing.
@immutable
class PlateGeometry {
  const PlateGeometry({
    required this.supportHalfWidthMm,
    required this.supportHalfLengthMm,
    required this.footprintHalfWidthMm,
    required this.footprintHalfLengthMm,
  });

  /// Half the left-right spacing between ground contacts.
  final double supportHalfWidthMm;

  /// Half the front-back spacing between ground contacts.
  final double supportHalfLengthMm;

  /// Half the left-right extent of the plate top surface.
  final double footprintHalfWidthMm;

  /// Half the front-back extent of the plate top surface.
  final double footprintHalfLengthMm;

  /// CoP x (support-normalized, ±1 = support edge) in millimetres.
  double copXmm(double copX) => copX * supportHalfWidthMm;

  /// CoP y (support-normalized) in millimetres.
  double copYmm(double copY) => copY * supportHalfLengthMm;

  /// The footprint half-width in support-normalized units, for drawing the
  /// top surface inside the CoP frame. Equals 1 when the contacts sit on the
  /// footprint edge; the bench's contacts splay wider, so it is < 1.
  double get footprintHalfWidthNorm =>
      footprintHalfWidthMm / supportHalfWidthMm;

  /// The footprint half-length in support-normalized units.
  double get footprintHalfLengthNorm =>
      footprintHalfLengthMm / supportHalfLengthMm;
}

/// Dev bench: 9" × 26" sheet with ground contacts splayed to 17.5" × 24"
/// (front-back aligned, contacts wider than the sheet). CoP lives in the
/// 17.5" × 24" contact frame — the sheet is only 9" wide.
const PlateGeometry benchPlate = PlateGeometry(
  supportHalfWidthMm: 222.25, // 17.5 in
  supportHalfLengthMm: 304.8, // 24 in
  footprintHalfWidthMm: 114.3, // 9 in
  footprintHalfLengthMm: 330.2, // 26 in
);

/// Geometry used by the branch's analysis. Production is a 400 × 600 mm
/// footprint with contact spacing still unset; when the hardware defines it,
/// add a [PlateGeometry] for it and switch this.
const PlateGeometry kPlateGeometry = benchPlate;

/// One plate sample: per-corner weights in kgf (tared net force). Corners
/// are top-left, top-right, bottom-left, bottom-right. (The math channels
/// mint the same basis over the derived-series machinery — see
/// `derived_channel.dart`; the analysis wants it as a flat tuple.)
typedef PlateWeights = ({double tl, double tr, double bl, double br});

extension PlateWeightsCoP on PlateWeights {
  double get total => tl + tr + bl + br;

  /// Center of pressure in normalized plate coordinates: ±1 = the plate
  /// edges, +x toward the right corners, +y toward the top ones. Null when
  /// the plate carries no positive load — at tare the weights hover at zero
  /// and the ratio would amplify noise instead of showing a position.
  (double, double)? get cop {
    final s = total;
    if (!(s > 0)) return null;
    return (((tr + br) - (tl + bl)) / s, ((tl + tr) - (bl + br)) / s);
  }
}

/// Raw ADC counts for [channel] at absolute sample [index].
typedef RawSampleAt = double Function(int channel, int index);

/// Reads the four corners of one plate into kgf force and CoP.
///
/// [corners] is the hardware channel per plate corner in [PlateWeights]
/// order [top-left, top-right, bottom-left, bottom-right]; the CoP x axis is
/// left-right and y is front-back.
class PlateReader {
  PlateReader._({
    required this.corners,
    required List<double Function(double raw)> cornerNets,
    required this.rawAt,
    required this.sampleRate,
    required this.geometry,
  }) : _cornerNets = cornerNets;

  final List<int> corners;

  /// kgf map for each corner, in corner order (same index space as [corners]).
  final List<double Function(double raw)> _cornerNets;

  final RawSampleAt rawAt;
  final int sampleRate;
  final PlateGeometry geometry;

  /// Bind a layout's four channel converters (kgf) to its raw stream. Throws
  /// when any corner channel cannot express kgf (no board map / no load cell):
  /// a plate reading is all four corners or nothing.
  factory PlateReader.forConverters({
    required List<ChannelConverter> converters,
    required RawSampleAt rawAt,
    required int sampleRate,
    List<int> corners = const [0, 1, 2, 3],
    PlateGeometry geometry = kPlateGeometry,
  }) {
    final reader = tryForConverters(
      converters: converters,
      rawAt: rawAt,
      sampleRate: sampleRate,
      corners: corners,
      geometry: geometry,
    );
    if (reader == null) {
      throw StateError('a corner channel cannot express kgf');
    }
    return reader;
  }

  /// [forConverters] as a probe: null when any corner channel cannot express
  /// kgf.
  static PlateReader? tryForConverters({
    required List<ChannelConverter> converters,
    required RawSampleAt rawAt,
    required int sampleRate,
    List<int> corners = const [0, 1, 2, 3],
    PlateGeometry geometry = kPlateGeometry,
  }) {
    assert(corners.length == 4, 'need four corner channels');
    final nets = <double Function(double)>[];
    for (final ch in corners) {
      final net = converters[ch].netMap(DisplayUnit.kgf);
      if (net == null) return null;
      nets.add(net);
    }
    return PlateReader._(
      corners: corners,
      cornerNets: nets,
      rawAt: rawAt,
      sampleRate: sampleRate,
      geometry: geometry,
    );
  }

  /// Bind a live or frozen data source; null when any corner channel cannot
  /// express kgf (see [tryForConverters]), or when the source's math profile
  /// has no plate semantics (a `none` rig is not a plate). The corner order
  /// comes from the profile: live from the rig config, frozen from the
  /// session's record-time snapshot.
  static PlateReader? tryForData(
    GraphDataSource data, {
    PlateGeometry geometry = kPlateGeometry,
  }) => switch (data.mathProfile.plateCorners) {
    null => null,
    final corners => tryForConverters(
      converters: [
        for (int ch = 0; ch < kAdcChannelCount; ch++) data.converterFor(ch),
      ],
      rawAt: (ch, i) => data.rawAt(ch, i).toDouble(),
      sampleRate: data.sampleRate,
      corners: corners,
      geometry: geometry,
    ),
  };

  /// Test/synthetic path: corner forces already in kgf, indexed by corner
  /// order [TL, TR, BL, BR] — no calibration involved.
  factory PlateReader.fromCornerForce(
    double Function(int corner, int index) cornerForceKgf, {
    required int sampleRate,
    PlateGeometry geometry = kPlateGeometry,
  }) => PlateReader._(
    corners: const [0, 1, 2, 3],
    cornerNets: [for (int i = 0; i < 4; i++) (raw) => raw],
    rawAt: (corner, index) => cornerForceKgf(corner, index),
    sampleRate: sampleRate,
    geometry: geometry,
  );

  /// The four corner weights at [index], in kgf.
  PlateWeights weightsAt(int index) => (
    tl: _cornerNets[0](rawAt(corners[0], index)),
    tr: _cornerNets[1](rawAt(corners[1], index)),
    bl: _cornerNets[2](rawAt(corners[2], index)),
    br: _cornerNets[3](rawAt(corners[3], index)),
  );
}

/// A captured window of plate samples: total force and CoP per sample, flat
/// arrays in absolute sample-index space. Both cold (segmentation and
/// metrics) and the live preview read the same object.
///
/// Everything downstream reads the RAW force: detection robustness is left to
/// time-domain rules (sustained crossings, mask morphology — see
/// `force_mask.dart`), because any low-pass envelope both delays edges and
/// still leaks the plate's ring through its sidelobes. The raw total is also
/// the integration signal: impulsive metrics need the actual area under the
/// curve, which a boxcar merely redistributes. The plate's mechanical ring
/// integrates to ~zero over full cycles, so leaving it in costs little.
class PlateWindow {
  PlateWindow._({
    required this.start,
    required this.sampleRate,
    required this.geometry,
    required this.totalKgf,
    required this.leftKgf,
    required this.rightKgf,
    required this.frontKgf,
    required this.backKgf,
    required this.copX,
    required this.copY,
  });

  /// Absolute sample index of element 0.
  final int start;
  final int sampleRate;

  /// The plate's geometry (converts support-normalized CoP to millimetres).
  final PlateGeometry geometry;

  /// Total plate force, kgf (raw).
  final Float64List totalKgf;

  /// Left (top-left + bottom-left) and right (top-right + bottom-right) force
  /// in kgf; their sum is [totalKgf].
  final Float64List leftKgf;
  final Float64List rightKgf;

  /// Front (top-left + top-right) and back pair force, like [leftKgf].
  final Float64List frontKgf;
  final Float64List backKgf;

  /// Support-normalized CoP, NaN where the plate carries no positive load
  /// (see [PlateWeights.cop]).
  final Float64List copX;
  final Float64List copY;

  int get length => totalKgf.length;

  /// Absolute sample index one past the last element.
  int get end => start + length;

  /// Capture `[start, end)` from [reader].
  static PlateWindow capture(PlateReader reader, int start, int end) {
    assert(end >= start);
    final n = end - start;
    final total = Float64List(n);
    final left = Float64List(n);
    final right = Float64List(n);
    final front = Float64List(n);
    final back = Float64List(n);
    final copX = Float64List(n);
    final copY = Float64List(n);
    for (int i = 0; i < n; i++) {
      final w = reader.weightsAt(start + i);
      total[i] = w.total;
      left[i] = w.tl + w.bl;
      right[i] = w.tr + w.br;
      front[i] = w.tl + w.tr;
      back[i] = w.bl + w.br;
      final cop = w.cop;
      copX[i] = cop?.$1 ?? double.nan;
      copY[i] = cop?.$2 ?? double.nan;
    }
    return PlateWindow._(
      start: start,
      sampleRate: reader.sampleRate,
      geometry: reader.geometry,
      totalKgf: total,
      leftKgf: left,
      rightKgf: right,
      frontKgf: front,
      backKgf: back,
      copX: copX,
      copY: copY,
    );
  }

  double forceAt(int index) => totalKgf[index - start];

  double leftAt(int index) => leftKgf[index - start];

  double rightAt(int index) => rightKgf[index - start];

  double frontAt(int index) => frontKgf[index - start];

  double backAt(int index) => backKgf[index - start];

  /// Support-normalized CoP at [index], or null under no positive load.
  (double, double)? copAt(int index) {
    final x = copX[index - start];
    if (x.isNaN) return null;
    return (x, copY[index - start]);
  }
}
