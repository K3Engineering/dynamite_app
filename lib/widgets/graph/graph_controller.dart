import 'dart:math' as math;

import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// Graph viewport controller (shared between force graph, derivative, minimap)
// ---------------------------------------------------------------------------

/// Viewport state: following the live edge, or parked on a fixed window.
@immutable
sealed class GraphViewport {
  const GraphViewport();
}

/// Following the live edge. [span] locks the visible window to a fixed sample
/// count; null means "show everything" (auto-expanding squeeze). The null
/// lock is only reachable once the retained data exceeds
/// [GraphController.minLiveSpan] (see [GraphController.goLive]), so its
/// window always starts exactly at the oldest sample -- both edges sit on
/// data, which is what lets the painter pin the view instead of floating it
/// on the live-edge estimate.
final class GraphLive extends GraphViewport {
  const GraphLive([this.span]);

  final int? span;
}

/// Parked on the fixed window [start, end) (absolute sample indices). Hub
/// resets drop it via [GraphController.reset].
final class GraphWindow extends GraphViewport {
  const GraphWindow(this.start, this.end);

  final int start;
  final int end;
}

class GraphController extends ChangeNotifier {
  final int minLiveSpan;

  GraphController({this.minLiveSpan = 0})
    : _viewport = _initialViewport(minLiveSpan);

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

  /// Snap to live mode -- follow the right edge. Derives the span lock from
  /// the current window (or keeps the existing lock when already live); this
  /// is the single funnel for entering live mode, so every entry applies the
  /// same maturity test below.
  void goLive({required int totalSamples, required int oldestSample}) {
    final int? lockedSpan;
    switch (_viewport) {
      case GraphLive(:final span):
        // Already live (e.g. a fresh stream resetting the view): keep the
        // current lock.
        lockedSpan = span;
      case GraphWindow(:final start, :final end):
        final currentSpan = end - start;
        if (currentSpan < defaultLiveSpan(totalSamples, oldestSample)) {
          // Zoomed in from the default view: lock to it. Compared against
          // the default live span, not the data on hand, which early in a
          // stream differs.
          lockedSpan = currentSpan;
        } else if (currentSpan > minLiveSpan) {
          // They zoomed out to see all available data (beyond minLiveSpan);
          // they want to see everything auto-expand.
          lockedSpan = null;
        } else {
          // They zoomed out, but we don't have much data yet. Lock to minimum
          // span so it cleanly starts scrolling once it hits 20s.
          lockedSpan = minLiveSpan;
        }
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
        // Parked windows never outlive the data's right edge; a negative start
        // is legitimate for a sparse young buffer. When retention eviction
        // (the ring wrap: only eviction moves the floor under a parked
        // window, which never STARTs left of oldestSample) reaches the left
        // edge, the whole window slides right onto the retention head, span
        // intact -- the evicted data is gone, so the view becomes a rolling
        // delay rather than collapsing into a 1-sample ghost.
        assert(
          start < end && end <= totalSamples,
          'window [$start, $end) out of bounds for $totalSamples samples',
        );
        final s = math.max(start, oldestSample);
        return (s, math.min(s + (end - start), totalSamples));
    }
  }

  /// Apply the window [newStart, newStart + span), clamped to the available
  /// data. Snaps to live mode when the window reaches the right edge.
  ///
  /// The single funnel for every window-moving interaction (pan, minimap
  /// tap/drag, pinch).
  void applyWindow(int newStart, int span, int totalSamples, int oldestSample) {
    final minStart = _minWindowStart(oldestSample, totalSamples, span);
    final start = math.max(newStart, minStart);
    final newEnd = start + span;

    // Park on the window; if it reaches the right edge, snap to live instead
    // (goLive derives the locked span from the window set here).
    _viewport = GraphWindow(start, newEnd);
    if (newEnd >= totalSamples) {
      goLive(totalSamples: totalSamples, oldestSample: oldestSample);
      return;
    }
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

    double effectiveFocal = focalFraction;
    if (anchorLiveEdge && focalFraction > 0.8) {
      effectiveFocal = 1.0;
    }

    final focal = baseStart + (effectiveFocal * baseSpan).round();
    int newStart = focal - (effectiveFocal * span).round();
    int newEnd = newStart + span;

    final minStart = _minWindowStart(oldestSample, totalSamples, span);

    if (newStart < minStart) {
      newStart = minStart;
      newEnd = newStart + span;
    }

    if (newEnd >= totalSamples) {
      // At the right edge -- enter/stay live. Like applyWindow, funnel
      // through goLive: a max-span zoom over mature data means "show
      // everything" (no lock, auto-expand), but over less than minLiveSpan
      // of data max span IS the minLiveSpan floor, and goLive reverts to
      // the default scrolling window -- an early "zoom out to max" looks
      // identical to the default view, so it must be the same state, not a
      // look-alike that starts squeezing instead of scrolling once the
      // data crosses minLiveSpan.
      _viewport = GraphWindow(totalSamples - span, totalSamples);
      goLive(totalSamples: totalSamples, oldestSample: oldestSample);
      return;
    }

    _viewport = GraphWindow(newStart, newEnd);
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
