import 'dart:math' as math;

import 'package:flutter/foundation.dart';

@immutable
sealed class GraphViewport {
  const new(this.generation);

  /// Data-stream identity; a change restores the initial viewport.
  final int generation;
}

/// Follow the live edge. Null [span] auto-expands with retained data.
final class GraphLive extends GraphViewport {
  const new([this.span, int generation = 0])
    : assert(span == null || span > 0),
      super(generation);

  final int? span;
}

/// Parked across the full retained range `[oldestSample, totalSamples)`.
final class GraphFull extends GraphViewport {
  const new([super.generation = 0]);
}

/// A fixed absolute sample window over its data-stream generation.
final class GraphWindow extends GraphViewport {
  const new(this.start, this.end, int generation)
    : assert(start < end),
      super(generation);

  final int start;
  final int end;
}

class GraphController extends ChangeNotifier {
  final int minLiveSpan;

  /// Whether right-edge windows follow arriving data. Static sources use
  /// parked windows even at the right edge, so zoom anchoring stays centered.
  final bool isLiveSource;

  new({this.minLiveSpan = 0, this.isLiveSource = true})
    : assert(minLiveSpan >= 0),
      assert(isLiveSource || minLiveSpan == 0),
      _viewport = _initialViewport(
        minLiveSpan,
        isLiveSource: isLiveSource,
        generation: 0,
      );

  GraphViewport _viewport;

  static GraphViewport _initialViewport(
    int minLiveSpan, {
    required bool isLiveSource,
    required int generation,
  }) {
    if (!isLiveSource) return GraphFull(generation);
    return minLiveSpan > 0
        ? GraphLive(minLiveSpan, generation)
        : GraphLive(null, generation);
  }

  GraphViewport get viewport => _viewport;
  bool get isLive => _viewport is GraphLive;

  void reset() {
    _viewport = _initialViewport(
      minLiveSpan,
      isLiveSource: isLiveSource,
      generation: _viewport.generation,
    );
    notifyListeners();
  }

  int defaultLiveSpan(int totalSamples, int oldestSample) =>
      math.max(totalSamples - oldestSample, minLiveSpan);

  static int _minWindowStart(int oldestSample, int totalSamples, int span) =>
      math.min(oldestSample, totalSamples - span);

  void goLive({
    required int span,
    required int totalSamples,
    required int oldestSample,
    int generation = 0,
  }) {
    if (!isLiveSource) {
      throw StateError('a static graph cannot follow a live edge');
    }
    final defaultSpan = defaultLiveSpan(totalSamples, oldestSample);
    final int? lockedSpan;
    if (span > 0 && span < defaultSpan) {
      lockedSpan = span;
    } else if (minLiveSpan > 0 && span <= minLiveSpan) {
      lockedSpan = minLiveSpan;
    } else {
      lockedSpan = null;
    }
    _viewport = GraphLive(lockedSpan, generation);
    notifyListeners();
  }

  /// Resolve the current window and reconcile it with the stream identity.
  /// A source notification is already driving this read, so resetting a stale
  /// generation here need not emit a nested controller notification.
  (int start, int end) effectiveRange(
    int totalSamples,
    int oldestSample, {
    int generation = 0,
  }) {
    if (_viewport.generation != generation) {
      _viewport = _initialViewport(
        minLiveSpan,
        isLiveSource: isLiveSource,
        generation: generation,
      );
    }
    switch (_viewport) {
      case GraphLive(:final span):
        final s = span ?? defaultLiveSpan(totalSamples, oldestSample);
        return (totalSamples - s, totalSamples);
      case GraphFull():
        if (oldestSample > totalSamples) {
          throw StateError(
            'invalid data bounds [$oldestSample, $totalSamples)',
          );
        }
        return (oldestSample, totalSamples);
      case GraphWindow(:final start, :final end):
        if (start >= end || end > totalSamples) {
          throw StateError(
            'window [$start, $end) out of bounds for $totalSamples samples',
          );
        }
        return (start, end);
    }
  }

  /// Apply a window, clamped to available data. Live sources snap to follow
  /// mode at the right edge; static sources remain parked there.
  void applyWindow(
    int newStart,
    int span,
    int totalSamples,
    int oldestSample, {
    int generation = 0,
  }) {
    if (!isLiveSource && (totalSamples <= oldestSample || span <= 0)) {
      _viewport = GraphFull(generation);
      notifyListeners();
      return;
    }
    final effectiveSpan = isLiveSource
        ? span
        : math.min(span, totalSamples - oldestSample);
    final minStart = _minWindowStart(oldestSample, totalSamples, effectiveSpan);
    final maxStart = totalSamples - effectiveSpan;
    final start = math.min(math.max(newStart, minStart), maxStart);
    if (isLiveSource && start + effectiveSpan >= totalSamples) {
      goLive(
        span: effectiveSpan,
        totalSamples: totalSamples,
        oldestSample: oldestSample,
        generation: generation,
      );
      return;
    }
    if (effectiveSpan <= 0) {
      throw ArgumentError.value(span, 'span', 'must be positive');
    }
    _viewport = GraphWindow(start, start + effectiveSpan, generation);
    notifyListeners();
  }

  void zoomTo(
    int newSpan,
    double focalFraction, {
    required int baseStart,
    required int baseSpan,
    required bool anchorLiveEdge,
    required int totalSamples,
    required int oldestSample,
    int generation = 0,
  }) {
    final maxSpan = defaultLiveSpan(totalSamples, oldestSample);
    final minSpan = math.min(50, maxSpan);
    final span = newSpan.clamp(minSpan, maxSpan);
    final focal = anchorLiveEdge && focalFraction > 0.8 ? 1.0 : focalFraction;
    final start =
        baseStart + (focal * baseSpan).round() - (focal * span).round();
    applyWindow(
      start,
      span,
      totalSamples,
      oldestSample,
      generation: generation,
    );
  }

  void pan(
    int deltaSamples,
    int totalSamples,
    int oldestSample, {
    int generation = 0,
  }) {
    final (s, e) = effectiveRange(
      totalSamples,
      oldestSample,
      generation: generation,
    );
    applyWindow(
      s + deltaSamples,
      e - s,
      totalSamples,
      oldestSample,
      generation: generation,
    );
  }

  void centerOn(
    int centerSample,
    int totalSamples,
    int oldestSample, {
    int generation = 0,
  }) {
    final (s, e) = effectiveRange(
      totalSamples,
      oldestSample,
      generation: generation,
    );
    applyWindow(
      centerSample - (e - s) ~/ 2,
      e - s,
      totalSamples,
      oldestSample,
      generation: generation,
    );
  }

  void zoom(
    double factor,
    double focalFraction,
    int totalSamples,
    int oldestSample, {
    int generation = 0,
  }) {
    final (s, e) = effectiveRange(
      totalSamples,
      oldestSample,
      generation: generation,
    );
    zoomTo(
      ((e - s) / factor).round(),
      focalFraction,
      baseStart: s,
      baseSpan: e - s,
      anchorLiveEdge: isLive,
      totalSamples: totalSamples,
      oldestSample: oldestSample,
      generation: generation,
    );
  }
}
