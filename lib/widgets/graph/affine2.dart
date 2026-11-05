import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A two-dimensional affine transform.
///
/// The matrix is row-major for projection:
///
/// ```text
/// px = xx * x + xy * y + tx
/// py = yx * x + yy * y + ty
/// ```
///
/// This is a pure Dart value so graph mapping can be tested without a Flutter
/// engine. [canvasTransform] is the bridge to Flutter's column-major API.
@immutable
final class Affine2 {
  const new({
    required this.xx,
    required this.xy,
    required this.yx,
    required this.yy,
    required this.tx,
    required this.ty,
  });

  /// Map raw `(A, B - A)` samples into plot pixels.
  ///
  /// The renderer supplies deviation (`B - A`) as `y`; detrending subtracts
  /// [offset] and `slope * A`, then the Y axis is flipped for canvas +Y-down.
  factory plot({
    required double xMin,
    required double xMax,
    required double yMin,
    required double yMax,
    required double width,
    required double height,
    double offset = 0,
    double slope = 0,
  }) {
    if (!xMin.isFinite ||
        !xMax.isFinite ||
        !yMin.isFinite ||
        !yMax.isFinite ||
        !width.isFinite ||
        !height.isFinite ||
        !offset.isFinite ||
        !slope.isFinite) {
      throw ArgumentError(
        'Plot bounds, size, offset and slope must be finite.',
      );
    }
    if (xMin == xMax || yMin == yMax || width <= 0 || height <= 0) {
      throw ArgumentError('Plot ranges must be nonzero and size positive.');
    }

    final double sx = width / (xMax - xMin);
    final double sy = height / (yMax - yMin);
    return Affine2(
      xx: sx,
      xy: 0,
      yx: slope * sy,
      yy: -sy,
      tx: -xMin * sx,
      // At raw y = offset - slope*x, displayedY = 0. With yMin/yMax
      // symmetric this is the vertical center; this form handles any range.
      ty: height + (yMin + offset) * sy,
    );
  }

  final double xx;
  final double xy;
  final double yx;
  final double yy;
  final double tx;
  final double ty;

  ({double x, double y}) project(double x, double y) =>
      (x: xx * x + xy * y + tx, y: yx * x + yy * y + ty);

  /// Return `this(inner(point))`.
  Affine2 compose(Affine2 inner) => Affine2(
    xx: xx * inner.xx + xy * inner.yx,
    xy: xx * inner.xy + xy * inner.yy,
    yx: yx * inner.xx + yy * inner.yx,
    yy: yx * inner.xy + yy * inner.yy,
    tx: xx * inner.tx + xy * inner.ty + tx,
    ty: yx * inner.tx + yy * inner.ty + ty,
  );

  Affine2 get inverse {
    final double determinant = xx * yy - xy * yx;
    if (determinant == 0 || !determinant.isFinite) {
      throw StateError('A singular Affine2 has no inverse.');
    }
    return Affine2(
      xx: yy / determinant,
      xy: -xy / determinant,
      yx: -yx / determinant,
      yy: xx / determinant,
      tx: (xy * ty - yy * tx) / determinant,
      ty: (yx * tx - xx * ty) / determinant,
    );
  }

  /// Flutter `Canvas.transform` storage: 4x4 column-major, Z untouched.
  Float64List get canvasTransform => Float64List(16)
    ..[0] = xx
    ..[1] = yx
    ..[4] = xy
    ..[5] = yy
    ..[10] = 1
    ..[12] = tx
    ..[13] = ty
    ..[15] = 1;

  /// Whether this old bake contains every raw point in [current]'s rectangle.
  ///
  /// The current logical pixel corners are mapped back to raw coordinates and
  /// then through this old projection. Affine extrema occur at corners. This
  /// check matters because rescaling cannot restore dots clipped out of the
  /// old texture; an expanding view must vector-draw until it is rebaked.
  bool covers(Affine2 current, double width, double height) {
    const double epsilon = 1e-7;
    final Affine2 currentToOld = compose(current.inverse);
    for (final (double x, double y) in [
      (0.0, 0.0),
      (width, 0.0),
      (0.0, height),
      (width, height),
    ]) {
      final p = currentToOld.project(x, y);
      if (p.x < -epsilon ||
          p.x > width + epsilon ||
          p.y < -epsilon ||
          p.y > height + epsilon) {
        return false;
      }
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is Affine2 &&
      xx == other.xx &&
      xy == other.xy &&
      yx == other.yx &&
      yy == other.yy &&
      tx == other.tx &&
      ty == other.ty;

  @override
  int get hashCode => Object.hash(xx, xy, yx, yy, tx, ty);
}
