import 'dart:math' as math;

import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// Graph viewport controller (shared between force graph, derivative, minimap)
// ---------------------------------------------------------------------------

/// Viewport state of a [GraphController]: either following the live (right)
/// edge or parked on a fixed window. Kept as a union so the two states can't
/// mix (e.g. a stale window start silently carried while live).
sealed class GraphViewport {
  const GraphViewport();
}

/// Following the live edge. [span] locks the visible window to a fixed sample
/// count; null means "show everything" (auto-expanding squeeze).
final class GraphLive extends GraphViewport {
  const GraphLive([this.span]);

  final int? span;
}

/// Parked on the fixed window [start, end) (absolute sample indices).
final class GraphWindow extends GraphViewport {
  const GraphWindow(this.start, this.end);

  final int start;
  final int end;
}

class GraphController extends ChangeNotifier {
  final int minLiveSpan;

  GraphController({this.minLiveSpan = 0})
    : _viewport = minLiveSpan > 0 ? GraphLive(minLiveSpan) : const GraphLive();

  GraphViewport _viewport;

  /// Whether we're following the live edge (auto-scroll with new data).
  bool get isLive => _viewport is GraphLive;

  /// Restore the initial state (a fresh stream erased the data: any pan/zoom
  /// window over the old trace is meaningless).
  void reset() {
    _viewport = minLiveSpan > 0 ? GraphLive(minLiveSpan) : const GraphLive();
    notifyListeners();
  }

  /// Snap to live mode -- follow the right edge.
  /// If [span] is provided, locks to that scrolling window.
  /// If not provided, derives the lock from the current window (or keeps the
  /// existing lock when already live).
  void goLive({
    int? span,
    required int totalSamples,
    required int oldestSample,
  }) {
    final int? lockedSpan;
    if (span != null) {
      // Explicitly lock to a span (used by zoom out when it hits max)
      lockedSpan = span;
    } else {
      switch (_viewport) {
        case GraphLive(:final span):
          // Already live (e.g. a fresh stream resetting the view): keep the
          // current lock.
          lockedSpan = span;
        case GraphWindow(:final start, :final end):
          final currentSpan = end - start;
          if (currentSpan <
              math.max(totalSamples - oldestSample, minLiveSpan)) {
            // Zoomed in from the default view: lock to it. Compared against
            // the default live span, not the data on hand: early in a
            // stream the two differ (e.g. a 17s window over 5s of data), and
            // the data comparison would misread that zoom as the "zoomed
            // out" cases below.
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
    }

    _viewport = GraphLive(lockedSpan);
    notifyListeners();
  }

  (int start, int end) effectiveRange(
    int totalSamples,
    int oldestSample, {
    int? bufferCapacity,
  }) {
    switch (_viewport) {
      case GraphLive(:final span):
        int s = span ?? math.max(minLiveSpan, totalSamples - oldestSample);
        if (bufferCapacity != null && s > bufferCapacity) {
          s = bufferCapacity;
        }
        return (totalSamples - s, totalSamples);
      case GraphWindow(:final start, :final end):
        // Defensive: a parked window can outlive the data (e.g. the hub is
        // cleared for a new stream while parked). Clamp the start first so
        // the end clamp can never receive inverted limits and throw.
        final s = math.min(math.max(start, 0), math.max(0, totalSamples - 1));
        final e = math.min(math.max(end, s + 1), math.max(totalSamples, s + 1));
        return (s, e);
    }
  }

  /// Apply the window [newStart, newStart + span), clamped to the available
  /// data. Snaps to live mode when the window reaches the right edge.
  ///
  /// This is the single funnel for every window-moving interaction (pan,
  /// minimap tap/drag, gesture pan); [zoomTo] handles the zooming ones.
  void applyWindow(int newStart, int span, int totalSamples, int oldestSample) {
    int newEnd = newStart + span;
    final minStart = math.min(oldestSample, totalSamples - span);

    if (newStart < minStart) {
      newStart = minStart;
      newEnd = newStart + span;
    }

    // Park on the window; if it reaches the right edge, snap to live instead
    // (goLive derives the locked span from the window set here).
    _viewport = GraphWindow(newStart, newEnd);
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
    final maxSpan = math.max(totalSamples - oldestSample, minLiveSpan);
    // Minimum ~50 samples visible (50ms at 1kHz) -- or the whole dataset when
    // less than that exists (a parked session of <50 samples): clamp(50, ...)
    // would invert the limits and throw there.
    final minSpan = math.min(50, maxSpan);
    final span = newSpan.clamp(minSpan, maxSpan);

    double effectiveFocal = focalFraction;
    if (anchorLiveEdge && focalFraction > 0.8) {
      effectiveFocal = 1.0;
    }

    final focal = baseStart + (effectiveFocal * baseSpan).round();
    int newStart = focal - (effectiveFocal * span).round();
    int newEnd = newStart + span;

    final minStart = math.min(oldestSample, totalSamples - span);

    if (newStart < minStart) {
      newStart = minStart;
      newEnd = newStart + span;
    }

    if (newEnd >= totalSamples) {
      // At the right edge -- enter/stay live. Unlike applyWindow, a zoom that
      // hits max span means "show everything" (no locked span, auto-expand).
      _viewport = GraphWindow(totalSamples - span, totalSamples);
      goLive(
        span: span >= maxSpan ? null : span,
        totalSamples: totalSamples,
        oldestSample: oldestSample,
      );
      return;
    }

    _viewport = GraphWindow(newStart, newEnd);
    notifyListeners();
  }

  /// Pan by a delta in samples (negative = left, positive = right).
  void pan(
    int deltaSamples,
    int totalSamples,
    int oldestSample,
    int bufferCapacity,
  ) {
    final (s, e) = effectiveRange(
      totalSamples,
      oldestSample,
      bufferCapacity: bufferCapacity,
    );
    applyWindow(s + deltaSamples, e - s, totalSamples, oldestSample);
  }

  /// Center the current window (span preserved) on [centerSample].
  void centerOn(
    int centerSample,
    int totalSamples,
    int oldestSample,
    int bufferCapacity,
  ) {
    final (s, e) = effectiveRange(
      totalSamples,
      oldestSample,
      bufferCapacity: bufferCapacity,
    );
    final span = e - s;
    applyWindow(centerSample - span ~/ 2, span, totalSamples, oldestSample);
  }

  /// Zoom by a factor around a focal point (0.0 = left edge, 1.0 = right edge).
  void zoom(
    double factor,
    double focalFraction,
    int totalSamples,
    int oldestSample,
    int bufferCapacity,
  ) {
    final (s, e) = effectiveRange(
      totalSamples,
      oldestSample,
      bufferCapacity: bufferCapacity,
    );
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
