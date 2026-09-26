// ---------------------------------------------------------------------------
// Balance math: two-cell position lines and the four-corner plate's center
// of pressure. Pure Dart (no Flutter); the panes only map results to pixels.
// ---------------------------------------------------------------------------

/// One plate sample: per-corner weights in display units (tared force).
/// Corners are top-left, top-right, bottom-left, bottom-right.
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

/// CoP spread from the four-corner plate's redundancy: each pair of cells
/// along an axis estimates that axis' coordinate on its own (top edge and
/// bottom edge for x; left and right for y). On a rigid plate the two
/// estimates agree no matter where the load sits; a flexing plate or a
/// misbehaving corner opens the axis it affects. Returns the (x, y)
/// half-differences, or null when either edge of an axis carries no positive
/// load — convergence is unknowable then.
(double, double)? copSpread(PlateWeights w) {
  final xTop = _edgePosition(w.tl, w.tr);
  final xBottom = _edgePosition(w.bl, w.br);
  final yLeft = _edgePosition(w.bl, w.tl);
  final yRight = _edgePosition(w.br, w.tr);
  if (xTop == null || xBottom == null || yLeft == null || yRight == null) {
    return null;
  }
  return ((xTop - xBottom).abs() / 2, (yLeft - yRight).abs() / 2);
}

/// One edge's position estimate: (b − a)/(a + b), null under no positive
/// load. Unlike [balancePosition] there's no clamp — a corner reading
/// negative legitimately pushes an edge past ±1, and clamping would hide
/// exactly the disagreement the convergence view exists to show.
double? _edgePosition(double a, double b) {
  final s = a + b;
  if (!(s > 0)) return null;
  return (b - a) / s;
}

/// 1D balance position of a two-cell pair: (b − a)/(a + b) ∈ [-1, 1], +1 =
/// all load on b. Null under no positive total load. Clamped to ±1.05 so
/// near-cancellation spikes (both cells near zero) pin to the plot edge
/// instead of poisoning the envelope's min/max math with huge values.
double? balancePosition(double a, double b) {
  final s = a + b;
  if (!(s > 0)) return null;
  return ((b - a) / s).clamp(-1.05, 1.05);
}
