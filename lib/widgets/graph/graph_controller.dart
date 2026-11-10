import 'dart:math' as math;

import 'package:flutter/foundation.dart';

@immutable
sealed class GraphViewport {
  const new();
}

/// Follow the live edge. Null [span] auto-expands with retained data.
final class GraphLive extends GraphViewport {
  const new([this.span]);

  final int? span;
}

/// A fixed absolute sample window, valid only for its data-stream generation.
final class GraphWindow extends GraphViewport {
  const new(this.start, this.end, this.generation);

  final int start;
  final int end;
  final int generation;
}

class GraphController extends ChangeNotifier {
  final int minLiveSpan;

  /// Whether right-edge windows follow arriving data. Static sources use
  /// parked windows even at the right edge, so zoom anchoring stays centered.
  final bool isLiveSource;

  new({this.minLiveSpan = 0, this.isLiveSource = true})
    : _viewport = _initialViewport(minLiveSpan);

  GraphViewport _viewport;

  static GraphViewport _initialViewport(int minLiveSpan) =>
      minLiveSpan > 0 ? GraphLive(minLiveSpan) : const GraphLive();

  GraphViewport get viewport => _viewport;
  bool get isLive => _viewport is GraphLive;

  void reset() {
    _viewport = _initialViewport(minLiveSpan);
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
  }) {
    if (!isLiveSource) {
      throw StateError('a static graph cannot follow a live edge');
    }
    final defaultSpan = defaultLiveSpan(totalSamples, oldestSample);
    final int? lockedSpan;
    if (span < defaultSpan) {
      lockedSpan = span;
    } else if (span <= minLiveSpan) {
      lockedSpan = minLiveSpan;
    } else {
      lockedSpan = null;
    }
    _viewport = GraphLive(lockedSpan);
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
    if (_viewport case GraphWindow(generation: final windowGeneration)
        when windowGeneration != generation) {
      _viewport = _initialViewport(minLiveSpan);
    }
    if (!isLiveSource && _viewport is GraphLive) {
      final live = _viewport as GraphLive;
      final s = live.span ?? defaultLiveSpan(totalSamples, oldestSample);
      _viewport = GraphWindow(totalSamples - s, totalSamples, generation);
    }
    switch (_viewport) {
      case GraphLive(:final span):
        final s = span ?? defaultLiveSpan(totalSamples, oldestSample);
        return (totalSamples - s, totalSamples);
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
    final start = math.max(
      newStart,
      _minWindowStart(oldestSample, totalSamples, span),
    );
    if (isLiveSource && start + span >= totalSamples) {
      goLive(
        span: span,
        totalSamples: totalSamples,
        oldestSample: oldestSample,
      );
      return;
    }
    _viewport = GraphWindow(start, start + span, generation);
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
