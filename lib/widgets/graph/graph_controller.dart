import 'dart:math' as math;

import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// Graph viewport controller (shared between force graph, derivative, minimap)
// ---------------------------------------------------------------------------

/// Viewport state: following the live edge, or parked on a fixed window.
@immutable
sealed class GraphViewport {
  const new();
}

/// Following the live edge. [span] locks the visible window to a fixed sample
/// count; null means "show everything" (auto-expanding squeeze). The null
/// lock is only reachable once the retained data exceeds
/// [GraphController.minLiveSpan] (see [GraphController.goLive]), so its
/// window always starts exactly at the oldest sample -- both edges sit on
/// data, which is what lets the painter pin the view instead of floating it
/// on the live-edge estimate.
final class GraphLive extends GraphViewport {
  const new([this.span]);

  final int? span;
}

/// Parked on the fixed window [start, end) (absolute sample indices). Hub
/// resets drop it via [GraphController.reset]. Retention eviction is NOT
/// chased: the window may lie partly or wholly left of `oldestSample`, and
/// the painters render that part blank (see [GraphController.effectiveRange]).
final class GraphWindow extends GraphViewport {
  const new(this.start, this.end);

  final int start;
  final int end;
}

class GraphController extends ChangeNotifier {
  final int minLiveSpan;

  new({this.minLiveSpan = 0}) : _viewport = _initialViewport(minLiveSpan);

  GraphViewport _viewport;

  static GraphViewport _initialViewport(int minLiveSpan) =>
      minLiveSpan > 0 ? GraphLive(minLiveSpan) : const GraphLive();

  /// Whether following the live edge.
  bool get isLive => _viewport is GraphLive;

  /// The locked span when rolling on the live edge ([GraphLive] with a
  /// span); null when parked or when live-showing everything. Only rolling
  /// windows float on the fractional live-edge estimate; parked and
  /// show-everything views are data-pinned, so nothing on screen moves
  /// between packet arrivals.
  int? get lockedLiveSpan => switch (_viewport) {
    GraphLive(:final span?) => span,
    _ => null,
  };

  /// Restore the initial state (a fresh stream erased the data: any pan/zoom
  /// window over the old trace is meaningless).
  void reset() {
    _viewport = _initialViewport(minLiveSpan);
    notifyListeners();
  }

  /// The span of the default live view (and of "show everything"): all
  /// retained data, floored at [minLiveSpan] so a young stream opens as a
  /// scrolling window over mostly-empty space instead of squeezing. The
  /// single derivation the zoom clamp, the go-live maturity test, and the
  /// minimap's squeezed range all share.
  int defaultLiveSpan(int totalSamples, int oldestSample) =>
      math.max(totalSamples - oldestSample, minLiveSpan);

  /// The leftmost allowed window start: retention's head, or the
  /// right-edge-flush position when less than [span] is retained (a negative
  /// start is legitimate on a sparse young buffer).
  static int _minWindowStart(int oldestSample, int totalSamples, int span) =>
      math.min(oldestSample, totalSamples - span);

  /// Snap to live mode -- follow the right edge, locking the visible [span]
  /// (null = "show everything", auto-expanding). The single funnel for
  /// entering live mode, so every entry applies the same maturity test.
  void goLive({
    required int span,
    required int totalSamples,
    required int oldestSample,
  }) {
    final defaultSpan = defaultLiveSpan(totalSamples, oldestSample);
    final int? lockedSpan;
    if (span < defaultSpan) {
      // Zoomed in from the default view: keep that zoom.
      lockedSpan = span;
    } else if (span <= minLiveSpan) {
      // Zoomed out, but we don't have much data yet: the floor IS the default
      // view, so lock to it -- it scrolls once the data crosses the floor.
      lockedSpan = minLiveSpan;
    } else {
      // Zoomed out to see all available data: auto-expand with arrivals.
      lockedSpan = null;
    }
    _viewport = GraphLive(lockedSpan);
    notifyListeners();
  }

  (int start, int end) effectiveRange(int totalSamples, int oldestSample) {
    switch (_viewport) {
      case GraphLive(:final span):
        final s = span ?? defaultLiveSpan(totalSamples, oldestSample);
        return (totalSamples - s, totalSamples);
      case GraphWindow(:final start, :final end):
        // Parked windows never outlive the data's RIGHT edge (assert below,
        // guarded by [GraphController.reset] on stream clear); a negative
        // start is legitimate for a sparse young buffer. The LEFT edge is
        // returned verbatim once retention eviction passes it: clamping to
        // oldestSample would scroll 10-min-old data behind a view the user
        // parked, and scrolling behind a non-live view reads as live. The
        // painters clip at the retention head instead
        // (graph_components.dart `_paintEnvelopeDataLayer`).
        assert(
          start < end && end <= totalSamples,
          'window [$start, $end) out of bounds for $totalSamples samples',
        );
        return (start, end);
    }
  }

  /// Apply the window [newStart, newStart + span), clamped to the available
  /// data. Snaps to live mode when the window reaches the right edge.
  ///
  /// The single funnel for every window-moving interaction (pan, minimap
  /// tap/drag, pinch).
  void applyWindow(int newStart, int span, int totalSamples, int oldestSample) {
    final start = math.max(
      newStart,
      _minWindowStart(oldestSample, totalSamples, span),
    );

    // Park on the window; if it reaches the right edge, snap to live instead.
    if (start + span >= totalSamples) {
      goLive(
        span: span,
        totalSamples: totalSamples,
        oldestSample: oldestSample,
      );
      return;
    }
    _viewport = GraphWindow(start, start + span);
    notifyListeners();
  }

  /// Zoom so the window becomes [newSpan] samples (clamped to a ~50 sample
  /// minimum and the available data), anchored at [focalFraction] (0.0 = left
  /// edge, 1.0 = right edge) of the base window [baseStart, baseStart +
  /// baseSpan). The base window is the current one for wheel/button zoom, or
  /// the gesture-start window for pinch.
  ///
  /// When [anchorLiveEdge] and the focal point is near the right edge, the
  /// anchor snaps to the right edge so we stay live without tracking jitter.
  void zoomTo(
    int newSpan,
    double focalFraction, {
    required int baseStart,
    required int baseSpan,
    required bool anchorLiveEdge,
    required int totalSamples,
    required int oldestSample,
  }) {
    final maxSpan = defaultLiveSpan(totalSamples, oldestSample);
    // Min ~50 samples visible, or the whole dataset when smaller (clamp would
    // invert and throw otherwise).
    final minSpan = math.min(50, maxSpan);
    final span = newSpan.clamp(minSpan, maxSpan);

    // A focal point near the right edge of a live view snaps to the edge.
    final focal = anchorLiveEdge && focalFraction > 0.8 ? 1.0 : focalFraction;
    final start = math.max(
      baseStart + (focal * baseSpan).round() - (focal * span).round(),
      _minWindowStart(oldestSample, totalSamples, span),
    );

    // At the right edge -- enter/stay live. Like applyWindow, funnel through
    // goLive: a max-span zoom over mature data means "show everything" (no
    // lock, auto-expand), while over a young stream max span IS the
    // [minLiveSpan] floor and goLive keeps the default scrolling window.
    if (start + span >= totalSamples) {
      goLive(
        span: span,
        totalSamples: totalSamples,
        oldestSample: oldestSample,
      );
      return;
    }
    _viewport = GraphWindow(start, start + span);
    notifyListeners();
  }

  /// Pan by a delta in samples (negative = left, positive = right).
  void pan(int deltaSamples, int totalSamples, int oldestSample) {
    final (s, e) = effectiveRange(totalSamples, oldestSample);
    applyWindow(s + deltaSamples, e - s, totalSamples, oldestSample);
  }

  /// Center the current window (span preserved) on [centerSample].
  void centerOn(int centerSample, int totalSamples, int oldestSample) {
    final (s, e) = effectiveRange(totalSamples, oldestSample);
    final span = e - s;
    applyWindow(centerSample - span ~/ 2, span, totalSamples, oldestSample);
  }

  /// Zoom by a factor around a focal point (0.0 = left edge, 1.0 = right edge).
  void zoom(
    double factor,
    double focalFraction,
    int totalSamples,
    int oldestSample,
  ) {
    final (s, e) = effectiveRange(totalSamples, oldestSample);
    final span = e - s;
    zoomTo(
      (span / factor).round(),
      focalFraction,
      baseStart: s,
      baseSpan: span,
      anchorLiveEdge: isLive,
      totalSamples: totalSamples,
      oldestSample: oldestSample,
    );
  }
}
