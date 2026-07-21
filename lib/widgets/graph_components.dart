import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/app_settings.dart';
import '../models/bucket_series.dart';
import '../models/force_unit.dart';
import '../models/gap_list.dart';
import '../models/graph_data_source.dart';

// ---------------------------------------------------------------------------
// Shared graph layout constants
// ---------------------------------------------------------------------------

/// Horizontal/vertical padding shared by the graph painters and the gesture
/// areas. [kGraphRightSpace] reserves room for the Y-axis labels.
const double kGraphLeftSpace = 8;
const double kGraphRightSpace = 56;
const double kGraphBottomSpace = 24;

/// Width available for plotting given a full widget [totalWidth].
double graphPlotWidth(double totalWidth) =>
    totalWidth - kGraphLeftSpace - kGraphRightSpace;

/// Record [draw] and synchronously rasterize it into a [widthPx] x [heightPx]
/// physical-pixel [ui.Image]. The canvas is pre-scaled by [dpr] so [draw]
/// works in logical pixels.
///
/// This is the only place a [ui.Picture] appears in this file: `toImageSync`
/// requires one as an intermediate, so it is created and disposed here and
/// only the image escapes.
ui.Image bakeImage(
  int widthPx,
  int heightPx,
  double dpr,
  void Function(Canvas canvas) draw,
) {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder)..scale(dpr));
  final pic = recorder.endRecording();
  final img = pic.toImageSync(widthPx, heightPx);
  pic.dispose();
  return img;
}

// ---------------------------------------------------------------------------
// Segmented graph cache
//
// One caching mechanism shared by every plot surface (minimap, force graph,
// derivative graph) in both viewing modes:
//   * slide   -- a fixed-span window slides over the data: blits are pure
//                translations and segments are reused as-is;
//   * squeeze -- the window spans the whole growing history: blits get a
//                corrective affine transform (both axis mappings are affine)
//                and segments are re-rendered on a rolling basis once they
//                drift past [kMaxSegmentDrift].
//
// On web there is no engine raster cache: a cached ui.Picture is re-executed
// by Skia every frame, so vector re-draws cost Dart AND raster time each
// frame. Baking immutable sample ranges into GPU-resident ui.Images pays that
// cost once; the steady-state per-frame cost is a handful of texture blits
// plus the vector-drawn live-edge sliver.
//
// Quality invariant: a texture is only ever produced by a vector render --
// never by resampling another texture -- so every on-screen pixel is at most
// ONE bilinear resample away from a vector render, scaled by at most
// ~kMaxSegmentDrift before a refresh re-sharpens it.
// ---------------------------------------------------------------------------

/// Target on-screen width (logical px) of one baked segment texture.
const double kSegmentTargetPx = 200;

/// Max relative scale drift (horizontal or vertical) a visible segment may
/// accumulate before its rolling re-render. Bounds the resampling quality
/// loss between bake and refresh.
const double kMaxSegmentDrift = 0.08;

/// Min on-screen width (logical px) of an uncovered range before a bake is
/// spent on it. Narrower gaps -- e.g. the live-edge sliver -- are drawn as
/// vectors every frame until they outgrow this.
const double kSegmentGapBakePx = 40;

/// Segment (re)bakes allowed per frame. Each costs ~1-2ms of UI-thread
/// toImageSync; raising this shortens the fill-in after zooms/jumps at the
/// price of larger per-frame spikes.
const int kSegmentBakeBudget = 1;

/// Cached segments more than this many target-widths outside the view are
/// evicted; textures on the tall graphs are ~0.5-2MB each, so the cache
/// cannot be unbounded.
const int kSegmentEvictionMargin = 8;

/// Blit filter for segment textures. [FilterQuality.low] (bilinear) hides
/// fractional-pixel offsets and the small drift scales; flip to
/// [FilterQuality.none] to A/B sharpness.
const FilterQuality kSegmentFilterQuality = FilterQuality.low;

/// Base padding (logical px) baked around a segment texture so AA stroke
/// bleed survives the image crop. Renderers that overshoot the segment
/// bounds (the graphs' one-block polyline join) pass a larger horizontal pad.
const double kSegmentImagePad = 4;

/// Renders samples [start, end) mapped to x in [0, ~texW) at the plot's
/// current y-mapping, and returns the exact content width (logical px) it
/// used -- at most [texW], which is the allocated ceil. Called both to bake
/// segment textures and to draw uncovered gaps directly to the frame canvas.
typedef SegmentRenderer =
    double Function(Canvas canvas, int start, int end, int texW);

/// One baked segment: an immutable vector render of samples [start, end)
/// plus the mapping it was baked under. Never mutated and never re-blitted
/// into another texture (so resampling loss cannot compound); replaced by a
/// fresh vector render when stale.
class GraphSegment {
  final ui.Image image;

  /// Sample range the texture covers (absolute indices, half-open).
  final int start;
  final int end;

  /// Logical px the content occupies in the texture (x in [0, contentW)
  /// after the [hPad] translate); the blit's x-scale reference.
  final double contentW;

  /// Y-mapping at bake: content rows [0, gh) covered values [yMax, yMin].
  final double yMin;
  final double yMax;

  /// Padding baked around the content (AA bleed / polyline overshoot).
  final double hPad;
  final double vPad;

  GraphSegment({
    required this.image,
    required this.start,
    required this.end,
    required this.contentW,
    required this.yMin,
    required this.yMax,
    required this.hPad,
    required this.vPad,
  });

  void dispose() => image.dispose();
}

class SegmentedGraphCache {
  /// Baked segments ordered by [GraphSegment.start]. Overlaps are allowed
  /// (a refresh may extend over a neighbor; clipped at blit time in the left
  /// segment's favor, which is always the fresher one); gaps are drawn as
  /// vectors or left blank until a bake covers them.
  final List<GraphSegment> _segments = [];

  // Config the segments were baked under (mismatch => drop them all). The
  // plot width gw is deliberately NOT part of this: a width change is pure
  // x-scale drift, so existing segments stay correct under the corrective
  // blit and re-sharpen via the rolling refresh.
  double _gh = -1;
  double _dpr = -1;
  List<Object?> _configKey = const [];

  void clear() {
    for (final s in _segments) {
      s.dispose();
    }
    _segments.clear();
  }

  void dispose() => clear();

  /// Draw the data layer for the window [viewStart, viewStart + viewSpan)
  /// mapped to x in [0, gw): blit cached segments under their corrective
  /// affine transforms, spend up to [kSegmentBakeBudget] segment (re)bakes,
  /// and vector-draw uncovered gaps up to [maxDirectGapPx] wide (wider gaps
  /// stay blank until the rolling bakes cover them).
  ///
  /// Returns true when bake work remains; the owner should then schedule
  /// another frame (static sources never fire repaint on their own).
  bool paint(
    Canvas canvas, {
    required List<Object?> configKey,
    required double gw,
    required double gh,
    required double dpr,
    required int viewStart,
    required int viewSpan,
    required double yMin,
    required double yMax,
    required int totalSamples,
    required double hPad,
    required double vPad,
    required double maxDirectGapPx,
    required SegmentRenderer render,
  }) {
    if ((gh - _gh).abs() > 0.1 ||
        dpr != _dpr ||
        !listEquals(configKey, _configKey)) {
      clear();
      _gh = gh;
      _dpr = dpr;
      _configKey = List.of(configKey);
    }

    final double pps = gw / viewSpan; // logical px per sample
    final int viewEnd = viewStart + viewSpan;
    final int targetSpan = math.max(1, (kSegmentTargetPx / pps).round());

    // Evict segments far outside the view.
    final int margin = kSegmentEvictionMargin * targetSpan;
    _segments.removeWhere((s) {
      if (s.end >= viewStart - margin && s.start <= viewEnd + margin) {
        return false;
      }
      s.dispose();
      return true;
    });

    bool baked = false;
    for (int i = 0; i < kSegmentBakeBudget; i++) {
      if (!_bakeOne(
        pps,
        gh,
        viewStart,
        viewEnd,
        yMin,
        yMax,
        totalSamples,
        targetSpan,
        hPad,
        vPad,
        render,
      )) {
        break;
      }
      baked = true;
    }

    _blitSegments(canvas, pps, gw, gh, viewStart, yMin, yMax);
    _drawGaps(
      canvas,
      pps,
      gh,
      viewStart,
      viewEnd,
      totalSamples,
      vPad,
      maxDirectGapPx,
      render,
    );

    return baked;
  }

  /// Uncovered sub-ranges of [viewStart, min(viewEnd, totalSamples)).
  List<(int, int)> _gaps(int viewStart, int viewEnd, int totalSamples) {
    final int domainEnd = math.min(viewEnd, totalSamples);
    final gaps = <(int, int)>[];
    int covered = viewStart;
    for (final s in _segments) {
      if (covered >= domainEnd) break;
      if (s.start > covered) {
        gaps.add((covered, math.min(s.start, domainEnd)));
      }
      covered = math.max(covered, s.end);
    }
    if (covered < domainEnd) gaps.add((covered, domainEnd));
    return gaps;
  }

  /// Perform at most one segment (re)bake. Priority:
  ///   1. the widest visible gap past [kSegmentGapBakePx] (live-edge sliver
  ///      absorb, bootstrap fill, newly exposed pan/zoom territory);
  ///   2. the visible segment furthest past its drift/size thresholds
  ///      (rolling refresh, merging undersized neighbors and splitting
  ///      oversized ranges).
  /// Returns whether a bake happened.
  bool _bakeOne(
    double pps,
    double gh,
    int viewStart,
    int viewEnd,
    double yMin,
    double yMax,
    int totalSamples,
    int targetSpan,
    double hPad,
    double vPad,
    SegmentRenderer render,
  ) {
    // --- Priority 1: widest gap past the bake threshold -------------------
    (int, int)? bakeGap;
    double widestPx = kSegmentGapBakePx;
    for (final g in _gaps(viewStart, viewEnd, totalSamples)) {
      final double w = (g.$2 - g.$1) * pps;
      if (w > widestPx) {
        widestPx = w;
        bakeGap = g;
      }
    }
    if (bakeGap != null) {
      int start = bakeGap.$1;
      final int end = math.min(bakeGap.$2, start + targetSpan);
      if (end <= start) return false;

      // Insertion point: first segment starting inside/after the gap.
      int at = 0;
      while (at < _segments.length && _segments[at].start < start) {
        at++;
      }
      // Absorb left neighbors while the merged bake stays within one target
      // width, so the live-edge segment grows in place (one bake per sliver)
      // instead of accumulating sliver-wide strips.
      while (at > 0 &&
          (end - _segments[at - 1].start) * pps <= kSegmentTargetPx) {
        at--;
        start = _segments[at].start;
        _segments[at].dispose();
        _segments.removeAt(at);
      }

      _segments.insert(
        at,
        _bake(start, end, pps, gh, yMin, yMax, hPad, vPad, render),
      );
      return true;
    }

    // --- Priority 2: staleness refresh -------------------------------------
    // Score each visible segment; > 1.0 means past a threshold. Under
    // uniform squeeze all segments drift together, so picking the worst
    // (first on ties) degenerates into a round-robin.
    int worst = -1;
    double worstScore = 1.0;
    for (int i = 0; i < _segments.length; i++) {
      final s = _segments[i];
      if (s.end <= viewStart || s.start >= viewEnd) continue;
      final double w = (s.end - s.start) * pps;
      final double xScale = w / s.contentW;
      final double yScale = (s.yMax - s.yMin) / (yMax - yMin);
      double score =
          math.max((1 - xScale).abs(), (1 - yScale).abs()) / kMaxSegmentDrift;
      // Oversized (zoom-in stretched it): refresh-with-split.
      score = math.max(score, w / (2 * kSegmentTargetPx));
      // Undersized (squeeze shrank it): refresh-with-merge; only useful once
      // there is a right neighbor to merge into.
      if (i + 1 < _segments.length) {
        score = math.max(score, kSegmentTargetPx / 2 / math.max(w, 0.001));
      }
      if (score > worstScore) {
        worstScore = score;
        worst = i;
      }
    }
    if (worst < 0) return false;

    final s = _segments[worst];
    final int newStart = s.start;
    int newEnd = s.end;
    int removeTo = worst;
    // Merge right neighbors while the result stays under 1.5 targets.
    while (removeTo + 1 < _segments.length) {
      final n = _segments[removeTo + 1];
      if (n.start > newEnd) break; // never merge across a gap
      if ((n.end - newStart) * pps > 1.5 * kSegmentTargetPx) break;
      newEnd = math.max(newEnd, n.end);
      removeTo++;
    }
    if ((newEnd - newStart) * pps < kSegmentTargetPx / 2) {
      // Still undersized (right neighbor too big to swallow whole): extend
      // into it; the overlap is clipped at blit time in this segment's
      // favor, and fully-covered neighbors are replaced outright.
      newEnd = math.min(totalSamples, newStart + targetSpan);
      while (removeTo + 1 < _segments.length &&
          _segments[removeTo + 1].end <= newEnd) {
        removeTo++;
      }
    }
    if ((newEnd - newStart) * pps > 2 * kSegmentTargetPx) {
      // Oversized: bake only the leading target-width range; the remainder
      // becomes a gap that fills in over the following frames.
      newEnd = newStart + targetSpan;
    }
    if (newEnd <= newStart) return false;

    final seg = _bake(
      newStart,
      newEnd,
      pps,
      gh,
      yMin,
      yMax,
      hPad,
      vPad,
      render,
    );
    for (int k = worst; k <= removeTo; k++) {
      _segments[k].dispose();
    }
    _segments.replaceRange(worst, removeTo + 1, [seg]);
    return true;
  }

  /// Vector-render samples [start, end) into a fresh texture sized to the
  /// range's current on-screen width, so its blit starts at scale ~1.
  GraphSegment _bake(
    int start,
    int end,
    double pps,
    double gh,
    double yMin,
    double yMax,
    double hPad,
    double vPad,
    SegmentRenderer render,
  ) {
    final int texW = math.max(1, ((end - start) * pps).ceil());
    double contentW = texW.toDouble();
    final img = bakeImage(
      ((texW + 2 * hPad) * _dpr).ceil(),
      ((gh + 2 * vPad) * _dpr).ceil(),
      _dpr,
      (c) {
        c.translate(hPad, vPad);
        contentW = render(c, start, end, texW);
      },
    );
    return GraphSegment(
      image: img,
      start: start,
      end: end,
      contentW: math.max(contentW, 0.001),
      yMin: yMin,
      yMax: yMax,
      hPad: hPad,
      vPad: vPad,
    );
  }

  /// Blit every visible segment under the current mapping.
  ///
  /// Texture x-px u covers sample s = start + u * (end - start) / contentW,
  /// which today lands at x = (s - viewStart) * pps -- affine, so one
  /// drawImageRect repositions the content exactly. Vertically, a valueToY
  /// of the form gh - (v - yMin) * gh / (yMax - yMin) is affine in
  /// (yMin, yMax), so a y scale+offset corrects for range changes (per-
  /// channel offsets like tares cancel out of the difference).
  void _blitSegments(
    Canvas canvas,
    double pps,
    double gw,
    double gh,
    int viewStart,
    double yMin,
    double yMax,
  ) {
    final double range = yMax - yMin;
    final paint = Paint()..filterQuality = kSegmentFilterQuality;
    double coveredX = 0;
    for (final s in _segments) {
      final double x1 = (s.start - viewStart) * pps;
      final double x2 = (s.end - viewStart) * pps;
      // Where ranges overlap, the LEFT segment is the fresher one (refreshes
      // only ever extend rightward over a neighbor), so clip this blit to
      // start where the previous coverage ends.
      final double clipL = math.max(coveredX, 0.0);
      final double clipR = math.min(x2, gw);
      coveredX = math.max(coveredX, x2);
      if (clipR <= clipL) continue;

      final double xs = (x2 - x1) / s.contentW;
      final double ys = (s.yMax - s.yMin) / range;
      final double yTop = gh * (1 - ys) + (yMin - s.yMin) * gh / range;

      canvas.save();
      canvas.clipRect(Rect.fromLTRB(clipL, -s.vPad, clipR, gh + s.vPad));
      canvas.drawImageRect(
        s.image,
        // Source is the CONTENT rect (content + pads), not the ceil'd image
        // bounds: the dead ceil column would otherwise bake a small scale
        // error into every blit, blurring even identity mappings.
        Rect.fromLTWH(
          0,
          0,
          (s.contentW + 2 * s.hPad) * _dpr,
          (gh + 2 * s.vPad) * _dpr,
        ),
        Rect.fromLTWH(
          x1 - s.hPad * xs,
          yTop - s.vPad * ys,
          (s.contentW + 2 * s.hPad) * xs,
          (gh + 2 * s.vPad) * ys,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  /// Vector-render the uncovered visible ranges (live-edge sliver, freshly
  /// exposed pan/zoom territory, bake backlog). Ranges wider than
  /// [maxDirectGapPx] are left blank -- the rolling bakes cover them within
  /// a few frames.
  void _drawGaps(
    Canvas canvas,
    double pps,
    double gh,
    int viewStart,
    int viewEnd,
    int totalSamples,
    double vPad,
    double maxDirectGapPx,
    SegmentRenderer render,
  ) {
    for (final (gs, ge) in _gaps(viewStart, viewEnd, totalSamples)) {
      final double w = (ge - gs) * pps;
      if (w <= 0 || w > maxDirectGapPx) continue;
      final double x = (gs - viewStart) * pps;
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(x, -vPad, x + w, gh + vPad));
      canvas.translate(x, 0);
      render(canvas, gs, ge, math.max(1, w.ceil()));
      canvas.restore();
    }
  }
}

// ---------------------------------------------------------------------------
// Shared Graph Data Source
// ---------------------------------------------------------------------------

/// Number of samples reduced into a single envelope/line "block".
///
/// One block becomes one min/avg/max reduction and one polyline vertex. When
/// zoomed in past 1 sample/pixel this clamps to 1 (one block per sample). The
/// last block in a range is allowed to be short.
int blockSizeFor(int viewSamples, double graphW) {
  assert(graphW > 0); // callers only paint into non-degenerate plot areas
  // floor => >= 1 sample/block, so the polyline never has more vertices than
  // pixels. The remainder (viewSamples % blockSize) lands in the short final block.
  return math.max(1, (viewSamples / graphW).floor());
}

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
          if (currentSpan < totalSamples - oldestSample) {
            // User is zoomed in to a specific window, lock to it
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

  /// Get the effective visible range given total data size.
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
    // Minimum ~50 samples visible (50ms at 1kHz)
    final span = newSpan.clamp(50, maxSpan);

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

// ---------------------------------------------------------------------------
// Channel colors
// ---------------------------------------------------------------------------

Color getChannelColor(int index) {
  const colors = [
    Colors.blueAccent,
    Colors.deepOrangeAccent,
    Colors.green,
    Colors.purple,
  ];
  return colors[index % colors.length];
}

/// Shared mouse-wheel zoom for graph surfaces (main graphs and minimap):
/// zooms the controller window about the cursor position.
void _handleGraphPointerScroll(
  PointerSignalEvent event,
  GraphDataSource data,
  GraphController ctrl,
  double graphWidth,
) {
  if (event is! PointerScrollEvent) return;
  final totalSamples = data.totalSamples;
  if (totalSamples == 0 || graphWidth <= 0) return;

  final focalFrac = ((event.localPosition.dx - kGraphLeftSpace) / graphWidth)
      .clamp(0.0, 1.0);
  final zoomFactor = event.scrollDelta.dy < 0 ? 1.2 : 1 / 1.2;
  ctrl.zoom(
    zoomFactor,
    focalFrac,
    totalSamples,
    data.oldestSample,
    data.bufferCapacity,
  );
}

// ---------------------------------------------------------------------------
// Bake pump (shared repaint driver for the rolling segment bake)
// ---------------------------------------------------------------------------

/// Extra repaint driver for the rolling segment bake: baking is rationed to
/// [kSegmentBakeBudget] segments per frame, so when work remains a painter
/// calls [schedule], which ticks [Listenable] listeners after the frame.
/// Needed for static sources (loaded sessions) whose [GraphDataSource.repaint]
/// never fires; harmless for live ones. Owned and disposed by the host
/// widget's State.
class BakePump implements Listenable {
  final ValueNotifier<int> _notifier = ValueNotifier<int>(0);
  bool _scheduled = false;
  bool _disposed = false;

  /// Schedule a one-shot post-frame tick (coalesced until it fires).
  void schedule() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) _notifier.value++;
    });
  }

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);

  void dispose() {
    _disposed = true;
    _notifier.dispose();
  }
}

// ---------------------------------------------------------------------------
// Minimap
// ---------------------------------------------------------------------------

/// Span of samples the minimap squeezes into its width: all available data,
/// clamped below by the controller's minimum live span.
int minimapSpan(int totalSamples, int oldestSample, int minLiveSpan) =>
    math.max(totalSamples - oldestSample, minLiveSpan);

class Minimap extends StatefulWidget {
  final GraphDataSource dataSource;
  final AppSettings settings;
  final GraphController graphCtrl;

  /// Indices of the channels to plot (per-view; see [GraphWorkspace]).
  final List<int> activeChannels;

  const Minimap({
    super.key,
    required this.dataSource,
    required this.settings,
    required this.graphCtrl,
    required this.activeChannels,
  });

  @override
  State<Minimap> createState() => _MinimapState();
}

class _MinimapState extends State<Minimap> {
  final SegmentedGraphCache _cache = SegmentedGraphCache();
  final BakePump _bakePump = BakePump();

  @override
  void dispose() {
    _bakePump.dispose();
    _cache.dispose();
    super.dispose();
  }

  void _onMinimapTap(TapDownDetails d, double graphWidth) {
    final totalSamples = widget.dataSource.totalSamples;
    if (totalSamples == 0 || graphWidth <= 0) return;
    final oldestSample = widget.dataSource.oldestSample;
    final frac = ((d.localPosition.dx - kGraphLeftSpace) / graphWidth).clamp(
      0.0,
      1.0,
    );
    final mapSpan = minimapSpan(
      totalSamples,
      oldestSample,
      widget.graphCtrl.minLiveSpan,
    );
    final mapStart = totalSamples - mapSpan;
    widget.graphCtrl.centerOn(
      mapStart + (frac * mapSpan).round(),
      totalSamples,
      oldestSample,
      widget.dataSource.bufferCapacity,
    );
  }

  void _onMinimapDrag(DragUpdateDetails d, double graphWidth) {
    final totalSamples = widget.dataSource.totalSamples;
    if (totalSamples == 0 || graphWidth <= 0) return;
    final oldestSample = widget.dataSource.oldestSample;
    final samplesPerPixel =
        minimapSpan(totalSamples, oldestSample, widget.graphCtrl.minLiveSpan) /
        graphWidth;
    widget.graphCtrl.pan(
      (d.delta.dx * samplesPerPixel).round(),
      totalSamples,
      oldestSample,
      widget.dataSource.bufferCapacity,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphWidth = graphPlotWidth(constraints.maxWidth);
        return SizedBox(
          height: 32,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerSignal: (e) => _handleGraphPointerScroll(
              e,
              widget.dataSource,
              widget.graphCtrl,
              graphWidth,
            ),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _onMinimapTap(d, graphWidth),
              onHorizontalDragUpdate: (d) => _onMinimapDrag(d, graphWidth),
              child: CustomPaint(
                foregroundPainter: _MinimapPainter(
                  widget.dataSource,
                  widget.settings,
                  widget.graphCtrl,
                  widget.activeChannels,
                  colorScheme,
                  dpr,
                  _cache,
                  _bakePump,
                  _bakePump.schedule,
                ),
                size: Size.infinite,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MinimapPainter extends CustomPainter {
  final GraphDataSource _data;
  final AppSettings _settings;
  final GraphController _ctrl;
  final List<int> _activeChannels;
  final ColorScheme _colorScheme;
  final double _dpr;
  final SegmentedGraphCache _cache;

  /// Asks the host widget to schedule another frame; called when bake work
  /// remains (rolling bootstrap / staleness passes) so it completes even for
  /// static sources whose [GraphDataSource.repaint] never fires.
  final VoidCallback _requestRepaint;

  _MinimapPainter(
    this._data,
    this._settings,
    this._ctrl,
    this._activeChannels,
    this._colorScheme,
    this._dpr,
    this._cache,
    Listenable bakePump,
    this._requestRepaint,
  ) : super(repaint: Listenable.merge([_data.repaint, _ctrl, bakePump]));

  @override
  void paint(Canvas canvas, Size size) {
    const double vPad = 2;

    canvas.translate(kGraphLeftSpace, vPad);
    final gw = size.width - kGraphLeftSpace - kGraphRightSpace;
    final gh = size.height - vPad * 2;

    if (gw <= 0 || gh <= 0) return;

    // Background
    final bgPaint = Paint()..color = _colorScheme.surface;
    canvas.drawRect(Rect.fromLTWH(0, 0, gw, gh), bgPaint);

    final totalSamples = _data.totalSamples;
    if (totalSamples == 0) return;

    final oldestSample = _data.oldestSample;
    final mapSpan = minimapSpan(totalSamples, oldestSample, _ctrl.minLiveSpan);
    final mapStart = totalSamples - mapSpan;

    final activeIndices = _activeChannels;
    final unit = _settings.displayUnit;

    // Y-range from the precomputed per-channel extremes (O(channels); the
    // minimap always spans the whole history, so the extremes ARE the window
    // min/max). Computed raw and tare-subtracted with a +/-10000-count floor
    // to keep the range non-degenerate on flat data, then converted to
    // display units to match the shared series evaluators.
    double rawMax = 10000;
    double rawMin = -10000;
    for (final ch in activeIndices) {
      final s = _data.channel(ch);
      final mx = s.max - s.tare;
      final mn = s.min - s.tare;
      if (mx > rawMax) rawMax = mx;
      if (mn < rawMin) rawMin = mn;
    }
    double yMin = unit.fromRaw(rawMin, _data.calibrationSlope);
    double yMax = unit.fromRaw(rawMax, _data.calibrationSlope);
    if (yMin > yMax) {
      // A negative display multiplier flipped the ordering.
      final t = yMin;
      yMin = yMax;
      yMax = t;
    }

    // Missing-data hatching, behind the data lines (same layering as the
    // main graphs).
    drawMissingDataHatching(
      canvas,
      Size(gw, gh),
      viewStart: mapStart,
      viewEnd: mapStart + mapSpan,
      data: _data,
      color: _colorScheme.error,
    );

    final tares = [for (final ch in activeIndices) _data.channel(ch).tare];

    // Segment-cached envelope data layer, shared with the main graphs. The
    // bucket-accelerated reduction keeps both segment bakes and direct gap
    // draws cheap even though every block spans many samples here.
    final workRemains = paintEnvelopeDataLayer(
      canvas,
      cache: _cache,
      data: _data,
      activeChannels: activeIndices,
      keyExtras: [...tares, unit, _data.calibrationSlope],
      gw: gw,
      gh: gh,
      dpr: _dpr,
      viewStart: mapStart,
      viewSpan: mapSpan,
      yMin: yMin,
      yMax: yMax,
      firstUsableSample: oldestSample,
      seriesFor: (ch) => EnvelopeSeries.bucketed(
        sampleAt: taredDisplaySampleAt(_data, ch, unit),
        buckets: _data.channel(ch).buckets,
        rawToDisplay: taredDisplayFromRaw(_data, ch, unit),
      ),
      avgStrokeWidth: 1.0,
      avgAlpha: 180,
    );
    if (workRemains) _requestRepaint();

    // Viewport highlight
    final (viewStart, viewEnd) = _ctrl.effectiveRange(
      totalSamples,
      oldestSample,
      bufferCapacity: _data.bufferCapacity,
    );
    final double x1 = (viewStart - mapStart) * gw / mapSpan;
    final double x2 = (viewEnd - mapStart) * gw / mapSpan;

    // Dim areas outside viewport
    final dimPaint = Paint()..color = _colorScheme.onSurface.withAlpha(60);
    if (x1 > 0) canvas.drawRect(Rect.fromLTWH(0, 0, x1, gh), dimPaint);
    if (x2 < gw) canvas.drawRect(Rect.fromLTWH(x2, 0, gw - x2, gh), dimPaint);

    // Viewport border
    final vpBorder = Paint()
      ..color = _colorScheme.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(Rect.fromLTRB(x1, 0, x2, gh), vpBorder);
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter oldDelegate) => true;
  // Repaints are driven by the repaint listenable (data + controller); a
  // painter is only replaced on a widget rebuild, which is rare enough that
  // one unconditional repaint beats keeping a field-by-field comparison in
  // sync with paint().
}
// ---------------------------------------------------------------------------
// Interactive Graph Area (handles gestures)
// ---------------------------------------------------------------------------

class InteractiveGraphArea extends StatefulWidget {
  final GraphDataSource data;
  final GraphController ctrl;
  final Widget child;

  const InteractiveGraphArea({
    super.key,
    required this.data,
    required this.ctrl,
    required this.child,
  });

  @override
  State<InteractiveGraphArea> createState() => _InteractiveGraphAreaState();
}

class _InteractiveGraphAreaState extends State<InteractiveGraphArea> {
  // Gesture tracking
  double? _panStartX;
  int? _panStartSample;
  int? _panEndSample;
  double? _scaleStartSpan;
  double? _pinchFocalX;
  bool _wasLiveOnScaleStart = false;

  void _onScaleStart(ScaleStartDetails details) {
    final total = widget.data.totalSamples;
    if (total == 0) return;

    final (s, e) = widget.ctrl.effectiveRange(
      total,
      widget.data.oldestSample,
      bufferCapacity: widget.data.bufferCapacity,
    );
    _panStartSample = s;
    _panEndSample = e;
    _panStartX = details.localFocalPoint.dx;
    _scaleStartSpan = (e - s).toDouble();
    _pinchFocalX = details.localFocalPoint.dx;
    _wasLiveOnScaleStart = widget.ctrl.isLive;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, double graphWidth) {
    final total = widget.data.totalSamples;
    if (total == 0 || _panStartSample == null || graphWidth <= 0) return;

    final origStart = _panStartSample!;
    final origSpan = _panEndSample! - origStart;
    final oldestSample = widget.data.oldestSample;

    if (details.scale != 1.0 && _scaleStartSpan != null) {
      // Pinch zoom, anchored to the gesture-start window so tracking stays
      // stable while totalSamples grows.
      widget.ctrl.zoomTo(
        (_scaleStartSpan! / details.scale).round(),
        (_pinchFocalX! / graphWidth).clamp(0.0, 1.0),
        baseStart: origStart,
        baseSpan: origSpan,
        anchorLiveEdge: _wasLiveOnScaleStart,
        totalSamples: total,
        oldestSample: oldestSample,
      );
    } else {
      // Pan by the horizontal drag distance, relative to the gesture-start
      // window.
      final dx = details.localFocalPoint.dx - _panStartX!;
      final deltaSamples = -(dx * origSpan / graphWidth).round();
      widget.ctrl.applyWindow(
        origStart + deltaSamples,
        origSpan,
        total,
        oldestSample,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphWidth = graphPlotWidth(constraints.maxWidth);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (e) => _handleGraphPointerScroll(
            e,
            widget.data,
            widget.ctrl,
            graphWidth,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: (d) => _onScaleUpdate(d, graphWidth),
            child: widget.child,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Graph Workspace Widget
// ---------------------------------------------------------------------------

class GraphWorkspace extends StatefulWidget {
  final GraphDataSource data;
  final GraphController ctrl;
  final AppSettings settings;

  /// Indices of the channels to plot. Kept per view (live tab, each session)
  /// rather than in [settings], so each surface chooses its own set.
  final List<int> activeChannels;
  final bool showDerivative;
  final bool isLiveGraph;
  final bool showZoomSpan;

  const GraphWorkspace({
    super.key,
    required this.data,
    required this.ctrl,
    required this.settings,
    required this.activeChannels,
    this.showDerivative = false,
    this.isLiveGraph = true,
    this.showZoomSpan = true,
  });

  @override
  State<GraphWorkspace> createState() => _GraphWorkspaceState();
}

class _GraphWorkspaceState extends State<GraphWorkspace> {
  final SegmentedGraphCache _forceCache = SegmentedGraphCache();
  final SegmentedGraphCache _derivCache = SegmentedGraphCache();
  final BakePump _bakePump = BakePump();

  @override
  void dispose() {
    _bakePump.dispose();
    _forceCache.dispose();
    _derivCache.dispose();
    super.dispose();
  }

  /// Zoom by [factor] (>1 in, <1 out), anchored at the live edge when
  /// following it and at the window center otherwise.
  void _zoomBy(double factor) {
    if (widget.data.totalSamples <= 0) return;
    widget.ctrl.zoom(
      factor,
      widget.ctrl.isLive ? 1.0 : 0.5,
      widget.data.totalSamples,
      widget.data.oldestSample,
      widget.data.bufferCapacity,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Column(
              children: [
                // Main force graph
                Expanded(
                  flex: widget.showDerivative ? 6 : 10,
                  child: InteractiveGraphArea(
                    data: widget.data,
                    ctrl: widget.ctrl,
                    child: CustomPaint(
                      foregroundPainter: ForceGraphPainter(
                        widget.data,
                        widget.settings,
                        widget.ctrl,
                        activeChannels: widget.activeChannels,
                        showXLabels: !widget.showDerivative,
                        cache: _forceCache,
                        colorScheme: colorScheme,
                        dpr: dpr,
                        bakePump: _bakePump,
                        requestRepaint: _bakePump.schedule,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
                // Derivative graph (when enabled)
                if (widget.showDerivative)
                  Expanded(
                    flex: 4,
                    child: InteractiveGraphArea(
                      data: widget.data,
                      ctrl: widget.ctrl,
                      child: CustomPaint(
                        foregroundPainter: DerivativeGraphPainter(
                          widget.data,
                          widget.settings,
                          widget.ctrl,
                          activeChannels: widget.activeChannels,
                          cache: _derivCache,
                          colorScheme: colorScheme,
                          dpr: dpr,
                          bakePump: _bakePump,
                          requestRepaint: _bakePump.schedule,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                // Minimap
                Minimap(
                  dataSource: widget.data,
                  settings: widget.settings,
                  graphCtrl: widget.ctrl,
                  activeChannels: widget.activeChannels,
                ),
              ],
            ),
            // LIVE button (appears when not following live edge)
            ListenableBuilder(
              listenable: widget.ctrl,
              builder: (context, _) {
                if (widget.ctrl.isLive ||
                    widget.data.totalSamples == 0 ||
                    !widget.isLiveGraph) {
                  return const SizedBox.shrink();
                }
                return Positioned(
                  right: 64,
                  top: 8,
                  child: FilledButton.tonalIcon(
                    onPressed: () => widget.ctrl.goLive(
                      totalSamples: widget.data.totalSamples,
                      oldestSample: widget.data.oldestSample,
                    ),
                    icon: const Icon(Icons.fast_forward, size: 16),
                    label: const Text('LIVE'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                );
              },
            ),
            // Zoom controls
            Positioned(
              right: 72,
              bottom: 72,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(24),
                color: Theme.of(context).colorScheme.primary,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.zoom_out,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                      onPressed: () => _zoomBy(1 / 1.2),
                    ),
                    if (widget.showZoomSpan)
                      ListenableBuilder(
                        listenable: Listenable.merge([
                          widget.ctrl,
                          widget.data.repaint,
                        ]),
                        builder: (context, _) {
                          final (start, end) = widget.ctrl.effectiveRange(
                            widget.data.totalSamples,
                            widget.data.oldestSample,
                            bufferCapacity: widget.data.bufferCapacity,
                          );
                          final spanSec =
                              (end - start) / widget.data.sampleRate;

                          String text;
                          if (spanSec < 1.0) {
                            text = '${(spanSec * 1000).round()} ms';
                          } else if (spanSec < 60.0) {
                            text = '${spanSec.toStringAsFixed(1)} s';
                          } else {
                            final m = spanSec ~/ 60;
                            final s = (spanSec % 60).floor().toString().padLeft(
                              2,
                              '0',
                            );
                            text = '$m:$s';
                          }

                          return Container(
                            width: 60,
                            alignment: Alignment.center,
                            child: Text(
                              text,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onPrimary,
                                fontWeight: FontWeight.bold,
                                fontFeatures: const [
                                  ui.FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    IconButton(
                      icon: Icon(
                        Icons.zoom_in,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                      onPressed: () => _zoomBy(1.2),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

typedef _ScaleConfigItem = ({int limit, int delta});

/// Clock-nice major tick steps for >= 1s spans (only consulted there, so the
/// smallest limit is the first one a span >= 1 can match).
const List<_ScaleConfigItem> _xScaleConfig = [
  (limit: 5, delta: 1),
  (limit: 10, delta: 2),
  (limit: 30, delta: 5),
  (limit: 60, delta: 10),
  (limit: 120, delta: 20),
  (limit: 300, delta: 30),
  (limit: 600, delta: 60),
];

_ScaleConfigItem _findScale(double val, List<_ScaleConfigItem> list) {
  return list.firstWhere((e) => val < e.limit, orElse: () => list.last);
}

/// Format an X-axis tick time (absolute seconds since session start) with
/// [decimals] fractional digits: "42", "0.35", "12:05", "1:00.5".
String _fmtTick(double sec, int decimals) {
  if (sec < 0) return '-${_fmtTick(-sec, decimals)}';
  // Snap fp noise (ticks are k * step products) so 59.999... prints as 1:00.
  final f = math.pow(10, decimals);
  sec = (sec * f).round() / f;
  final int m = sec ~/ 60;
  final s = (sec - m * 60).toStringAsFixed(decimals);
  if (m == 0) return s;
  return '$m:${s.padLeft(decimals == 0 ? 2 : decimals + 3, '0')}';
}

// Label paragraph cache, bounded: fully cleared on overflow — the per-frame
// working set is only a few dozen labels, so a clear just rebuilds the
// visible ones on the next paint.
const int _labelCacheLimit = 512;
final Map<String, ui.Paragraph> _labelCache = HashMap();

ui.Paragraph _prepareLabel(String text, {Color color = Colors.black}) {
  final key = '$text|${color.toARGB32()}';
  if (!_labelCache.containsKey(key) &&
      _labelCache.length >= _labelCacheLimit) {
    for (final paragraph in _labelCache.values) {
      paragraph.dispose();
    }
    _labelCache.clear();
  }
  return _labelCache.putIfAbsent(key, () {
    final style = ui.TextStyle(color: color, fontSize: 11);
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(textAlign: TextAlign.left, maxLines: 1),
          )
          ..pushStyle(style)
          ..addText(text);
    return builder.build()..layout(const ui.ParagraphConstraints(width: 80));
  });
}

// ---------------------------------------------------------------------------
// Compute nice Y-axis range for data that spans [dataMin, dataMax] in display units.
// Returns (yMin, yMax, tickDelta) where yMin <= 0 <= yMax (if data crosses zero)
// and tickDelta is the spacing between major ticks.
// ---------------------------------------------------------------------------

typedef YAxisRange = ({double yMin, double yMax, double tickDelta});

YAxisRange _computeYRange(double dataMin, double dataMax) {
  // Ensure some minimum range to avoid degenerate axes
  if (dataMax - dataMin < 0.001) {
    dataMax = dataMin + 1.0;
  }

  // Pick a nice 1/2/5 tick delta aiming for ~5 ticks, with a floor so labels
  // stay within 3 decimals.
  final tickDelta = math.max(0.001, _niceNum((dataMax - dataMin) / 5));

  // Snap yMin and yMax to tick boundaries
  final yMin = (dataMin / tickDelta).floor() * tickDelta;
  final yMax = (dataMax / tickDelta).ceil() * tickDelta;

  return (yMin: yMin, yMax: yMax, tickDelta: tickDelta);
}

// ---------------------------------------------------------------------------
// Shared plot toolkit
//
// Small reusable drawing primitives used by every graph painter (force,
// derivative, and future X-Y / FFT plots). Keeping them as free functions lets
// new plot types reuse axis and envelope rendering instead of copy-pasting.
// ---------------------------------------------------------------------------

/// Append vertical X-axis grid lines (and optional time labels) for the visible
/// window [viewStart, viewEnd) to [grid]. Times are absolute -- seconds since
/// sample 0 (session start) -- at every zoom level. When [drawMinor] is true,
/// half-step minor lines are added between the major ticks.
void drawTimeAxis(
  Canvas canvas,
  Path grid,
  Size graphSz, {
  required int viewStart,
  required int viewEnd,
  required int sampleRate,
  required bool showLabels,
  bool drawMinor = false,
  Color textColor = Colors.black,
}) {
  final viewSamples = viewEnd - viewStart;
  if (viewSamples <= 0) return;

  final startSec = viewStart / sampleRate;
  final endSec = viewEnd / sampleRate;
  final xSpanSec = viewSamples / sampleRate;

  // Aim for ~5 major ticks: decade 1/2/5 steps below one second, clock-nice
  // steps (1, 2, 5, 10, 30, 60s, ...) above.
  final double step = xSpanSec < 1.0
      ? _niceNum(xSpanSec / 5)
      : _findScale(xSpanSec, _xScaleConfig).delta.toDouble();
  final int decimals = step >= 1
      ? 0
      : (-(math.log(step) / math.ln10).floor()).clamp(1, 3).toInt();

  void vline(double sec, {required bool labeled}) {
    final xPos = (sec - startSec) * sampleRate * graphSz.width / viewSamples;
    grid.moveTo(xPos, 0);
    grid.lineTo(xPos, graphSz.height);
    if (labeled) {
      final par = _prepareLabel(_fmtTick(sec, decimals), color: textColor);
      canvas.drawParagraph(
        par,
        Offset(xPos - par.longestLine / 2, graphSz.height + 2),
      );
    }
  }

  // Ticks live on the absolute grid k * step, so they hold still while the
  // window slides over them.
  for (int k = (startSec / step).ceil(); k * step < endSec; k++) {
    vline(k * step, labeled: showLabels);
  }
  if (drawMinor) {
    // Minor lines at half-step offsets; these never coincide with a major.
    for (
      int k = (startSec / step - 0.5).ceil();
      (k + 0.5) * step < endSec;
      k++
    ) {
      vline((k + 0.5) * step, labeled: false);
    }
  }
}

/// Append horizontal Y-axis grid lines and labels (formatted by [labelFor]) for
/// [yRange] to [grid]. When [drawMinor] is true, half-delta minor lines are
/// added. [valueToY] maps an axis value to a pixel Y.
void drawValueAxis(
  Canvas canvas,
  Path grid,
  Size graphSz,
  YAxisRange yRange,
  double Function(double value) valueToY, {
  required String Function(double tick) labelFor,
  bool drawMinor = false,
  Color textColor = Colors.black,
}) {
  final delta = yRange.tickDelta;
  for (
    double tick = (yRange.yMin / delta).ceil() * delta;
    tick <= yRange.yMax + delta * 0.01;
    tick += delta
  ) {
    final yPos = valueToY(tick);
    if (yPos >= -1 && yPos <= graphSz.height + 1) {
      grid.moveTo(0, yPos);
      grid.lineTo(graphSz.width, yPos);
      final par = _prepareLabel(labelFor(tick), color: textColor);
      canvas.drawParagraph(
        par,
        Offset(graphSz.width + 4, yPos - par.height / 2),
      );
    }
  }

  if (drawMinor) {
    final minorDelta = delta / 2;
    for (
      double tick = (yRange.yMin / minorDelta).ceil() * minorDelta;
      tick <= yRange.yMax + minorDelta * 0.01;
      tick += minorDelta
    ) {
      final yPos = valueToY(tick);
      if (yPos >= -1 && yPos <= graphSz.height + 1) {
        grid.moveTo(0, yPos);
        grid.lineTo(graphSz.width, yPos);
      }
    }
  }
}

/// Draw a horizontal zero baseline if the axis range crosses zero.
void drawZeroBaseline(
  Canvas canvas,
  Size graphSz,
  YAxisRange yRange,
  double Function(double value) valueToY,
  Color color,
) {
  if (yRange.yMin < 0 && yRange.yMax > 0) {
    final zeroY = valueToY(0);
    canvas.drawLine(
      Offset(0, zeroY),
      Offset(graphSz.width, zeroY),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
  }
}

/// Draws a diagonal warning hatch pattern over the [GraphDataSource.gaps]
/// ranges visible in the window (regions where packets were dropped).
void drawMissingDataHatching(
  Canvas canvas,
  Size graphSz, {
  required int viewStart,
  required int viewEnd,
  required GraphDataSource data,
  required Color color,
}) {
  final gaps = data.gaps;
  if (gaps.isEmpty) return;

  final sScanStart = math.max(viewStart, data.oldestSample);
  final sScanEnd = math.min(viewEnd, data.totalSamples);
  if (sScanStart >= sScanEnd) return;

  final viewSamples = viewEnd - viewStart;
  if (viewSamples <= 0) return;

  double xOf(int sampleIdx) =>
      (sampleIdx - viewStart) * graphSz.width / viewSamples;

  final hatchPen = Paint()
    ..color = color.withAlpha(60)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;
  final bgPen = Paint()
    ..color = color.withAlpha(20)
    ..style = PaintingStyle.fill;

  void drawHatchRegion(int startIdx, int endIdx) {
    final xStart = xOf(startIdx);
    final xEnd = xOf(endIdx);

    // Hatch line spacing
    const double spacing = 8.0;

    // Draw diagonals from bottom-left to top-right
    final cStart = xStart - graphSz.height;
    final cEnd = xEnd;

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(xStart, 0, xEnd, graphSz.height));

    for (
      double c = (cStart / spacing).floor() * spacing;
      c <= cEnd;
      c += spacing
    ) {
      canvas.drawLine(
        Offset(c, graphSz.height),
        Offset(c + graphSz.height, 0),
        hatchPen,
      );
    }

    // Also draw a light background fill to make it pop
    canvas.drawRect(Rect.fromLTRB(xStart, 0, xEnd, graphSz.height), bgPen);

    canvas.restore();
  }

  for (final (gs, ge) in gaps.rangesIn(sScanStart, sScanEnd)) {
    drawHatchRegion(gs, ge);
  }
}

/// Accumulates 2D vertices into a fixed [Float32List] and flushes them in
/// bounded chunks, staying within the web (Skwasm/Emscripten) stack-allocation
/// limit of 4096 floats per draw call.
///
/// On flush, the trailing [preserveFloats] floats are carried over to the front
/// of the buffer so a continuous primitive (triangle strip or polyline) is not
/// broken across flushes. [drawThreshold] is the minimum filled-float count
/// required before a flush actually emits anything.
///
/// NOTE: this batching only exists for the web stack limit; with the current
/// architecture it can eventually be removed once that limit is lifted/tested.
class VertexBatcher {
  VertexBatcher({
    required this.preserveFloats,
    required this.drawThreshold,
    required this.onFlush,
    int capacity = 4096,
  }) : _buf = Float32List(capacity);

  final Float32List _buf;
  final int preserveFloats;
  final int drawThreshold;

  /// Draws the populated `[0, length)` view of the backing buffer.
  final void Function(Float32List view) onFlush;

  int _len = 0;

  /// Remaining capacity before a flush is forced.
  int get _capacity => _buf.length;

  /// Append a single (x, y) vertex.
  void add(double x, double y) {
    _buf[_len++] = x;
    _buf[_len++] = y;
  }

  /// Whether [extraFloats] more floats would overflow the buffer.
  bool wouldOverflow(int extraFloats) => _len + extraFloats > _capacity;

  /// Emit the accumulated vertices (if past [drawThreshold]) and reset, keeping
  /// the trailing [preserveFloats] floats so the primitive stays continuous.
  void flush() {
    if (_len > drawThreshold) {
      onFlush(Float32List.sublistView(_buf, 0, _len));
      for (int i = 0; i < preserveFloats; i++) {
        _buf[i] = _buf[_len - preserveFloats + i];
      }
      _len = preserveFloats;
    }
  }
}

/// The (average polyline, min/max envelope fill) [VertexBatcher] pair shared
/// by the envelope renderers. Both batchers reuse one [Paint], restyled per
/// flush.
({VertexBatcher avg, VertexBatcher env}) _envelopeBatchers(
  Canvas canvas, {
  required Color avgColor,
  required double avgStrokeWidth,
  required Color envColor,
}) {
  final pen = Paint();

  final avg = VertexBatcher(
    preserveFloats: 2,
    drawThreshold: 2,
    onFlush: (view) {
      pen
        ..color = avgColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = avgStrokeWidth;
      canvas.drawRawPoints(ui.PointMode.polygon, view, pen);
    },
  );

  final env = VertexBatcher(
    preserveFloats: 4,
    drawThreshold: 4,
    onFlush: (view) {
      final vertices = ui.Vertices.raw(ui.VertexMode.triangleStrip, view);
      pen
        ..color = envColor
        ..style = PaintingStyle.fill;
      canvas.drawVertices(vertices, ui.BlendMode.srcOver, pen);
      vertices.dispose();
    },
  );

  return (avg: avg, env: env);
}

/// Render one channel as a min/avg/max envelope across [graphW] pixel columns.
///
/// For each block the samples mapped to it are reduced to min/avg/max, then
/// projected with [valueToY]. The shaded envelope is filled at low alpha and
/// the average is stroked on top.
///
/// Blocks are anchored to absolute sample indices so the geometry lands on
/// the same pixels regardless of scroll, which is what makes it segment-
/// cacheable.
///
/// ## Block reduction: exact vs bucket-accelerated
///
/// By default each block is reduced by evaluating [EnvelopeSeries.sampleAt]
/// per sample ([reduceBlockExact]) -- exact, but O(samples) per bake, which
/// is too slow when a zoomed-out block spans thousands of samples. A series
/// built with [EnvelopeSeries.bucketed] switches to [reduceBlockBuckets]
/// whenever `blockSize >= 2 * bucketSize`; see its doc for the ACCURACY
/// TRADEOFF at partial bucket boundaries and the ring-wrap handling.
///
/// Gap handling: [paintEnvelopeDataLayer] clips all data ink out of the gap
/// x-ranges, so neither reduction path draws inside a gap. Within the
/// remaining (clipped-in) area the paths still differ slightly at gap edges:
/// the exact path excludes gap samples via NaN, while the buckets contain
/// held values, biasing the fast path's boundary blocks toward the pre-gap
/// value.
///
/// Vertices are flushed in <=4096-float chunks to stay within the web
/// (Skwasm/Emscripten) stack-allocation limit.
void drawChannelEnvelope(
  Canvas canvas, {
  required Color color,
  required double graphW,
  required int viewStart,
  required int viewSamples,
  required int totalSamples,
  required int firstUsableSample,
  required EnvelopeSeries series,
  required double Function(double value) valueToY,
  required int clipEnvelopeSamples,
  double avgStrokeWidth = 1.5,
  int avgAlpha = 255,
  int envAlpha = 60,
}) {
  final (avg: avg, env: env) = _envelopeBatchers(
    canvas,
    avgColor: color.withAlpha(avgAlpha),
    avgStrokeWidth: avgStrokeWidth,
    envColor: color.withAlpha(envAlpha),
  );

  // Calculate alignment block size
  final int blockSize = blockSizeFor(viewSamples, graphW);

  // Bucket acceleration only pays off (and only stays accurate, see the
  // ACCURACY TRADEOFF on reduceBlockBuckets) once a block spans at least
  // two buckets.
  final buckets = series.buckets;
  final bool useBuckets =
      buckets != null && blockSize >= 2 * buckets.bucketSize;

  // Blocks are anchored to absolute sample 0 (sStart = k * blockSize), NOT to
  // viewStart. This is what lets a block fall on the same pixels regardless of
  // scroll, so the SegmentedGraphCache can bake it once and reuse it.
  final int startBlock = (math.max(viewStart, firstUsableSample) / blockSize)
      .floor();
  final int endBlock = (totalSamples / blockSize).ceil();

  for (int k = startBlock; k < endBlock; k++) {
    final int sStart = k * blockSize;
    final int sEnd = math.min(
      sStart + blockSize,
      totalSamples,
    ); // last block may be short

    final int drawStart = math.max(sStart, firstUsableSample);
    if (drawStart >= sEnd) continue;
    // sEnd - drawStart in [1, blockSize]; the full-blockSize case is the common
    // one, but do NOT assert it: the trailing block and a block clipped by
    // firstUsableSample are both legitimately shorter.
    assert(sEnd - drawStart >= 1 && sEnd - drawStart <= blockSize);

    final BlockReduction r = useBuckets
        ? reduceBlockBuckets(series, drawStart, sEnd)
        : reduceBlockExact(series.sampleAt, drawStart, sEnd);

    if (r.count == 0) {
      // Entire block is dropped samples. Break the polyline.
      env.flush();
      avg.flush();
      continue;
    }

    final avgY = valueToY(r.sum / r.count);
    final minY = valueToY(r.min);
    final maxY = valueToY(r.max);

    // Absolute X (in this canvas's local space): a baked segment passes its
    // own start as viewStart, so xPos is segment-local and the segment slides
    // as a whole.
    final double xPos = (sStart - viewStart) * graphW / viewSamples;
    final double nextXPos = (sEnd - viewStart) * graphW / viewSamples;

    avg.add(xPos, avgY);

    if (sStart < clipEnvelopeSamples) {
      env.add(xPos, maxY);
      env.add(xPos, minY);
      env.add(nextXPos, maxY);
      env.add(nextXPos, minY);

      if (env.wouldOverflow(8)) env.flush();
    }

    if (avg.wouldOverflow(2)) avg.flush();
  }

  env.flush();
  avg.flush();
}

/// Per-sample evaluator for [channel]'s tared value in [unit] (NaN marks a
/// gap sample, breaking the polyline). The exact-path counterpart of
/// [taredDisplayFromRaw]; used by the force graph and the minimap.
double Function(int j) taredDisplaySampleAt(
  GraphDataSource data,
  int channel,
  ForceUnit unit,
) {
  final s = data.channel(channel);
  final line = s.data;
  final tare = s.tare;
  final bufferCap = data.bufferCapacity;
  final gaps = data.gaps;
  final slopeToUnit = unit.multiplierFromRaw(data.calibrationSlope);
  return (j) {
    if (gaps.contains(j)) return double.nan; // break the polyline
    return (line[j % bufferCap] - tare) * slopeToUnit;
  };
}

/// Affine raw-counts -> display-units map for [channel] (tare offset + unit
/// scale). Must agree with [taredDisplaySampleAt] outside gaps; feeds the
/// bucket fast path of [drawChannelEnvelope].
double Function(double raw) taredDisplayFromRaw(
  GraphDataSource data,
  int channel,
  ForceUnit unit,
) {
  final tare = data.channel(channel).tare;
  final slopeToUnit = unit.multiplierFromRaw(data.calibrationSlope);
  return (raw) => (raw - tare) * slopeToUnit;
}

/// Paint the segment-cached envelope data layer for the window
/// [viewStart, viewStart + viewSpan) mapped to x in [0, gw): the pipeline
/// shared by the force graph, derivative graph, and minimap. Handles the
/// cache configuration (keying, pads, block sizing) and renders one
/// min/avg/max envelope per active channel via [drawChannelEnvelope].
///
/// [seriesFor] returns the per-channel rendering recipe ([EnvelopeSeries]):
/// the exact per-sample evaluator plus optional bucket acceleration for the
/// block reduction (see [reduceBlockBuckets] for the accuracy tradeoff) --
/// use [EnvelopeSeries.exact] for series that cannot use buckets.
///
/// Returns true when bake work remains; the owner should then schedule
/// another frame.
bool paintEnvelopeDataLayer(
  Canvas canvas, {
  required SegmentedGraphCache cache,
  required GraphDataSource data,
  required List<int> activeChannels,
  required List<Object?> keyExtras,
  required double gw,
  required double gh,
  required double dpr,
  required int viewStart,
  required int viewSpan,
  required double yMin,
  required double yMax,
  required int firstUsableSample,
  required EnvelopeSeries Function(int channel) seriesFor,
  double avgStrokeWidth = 1.5,
  int avgAlpha = 255,
  int envAlpha = 60,
}) {
  final totalSamples = data.totalSamples;

  double valueToY(double val) =>
      (gh - (val - yMin) * gh / (yMax - yMin)).clamp(0.0, gh);

  final int blockSize = blockSizeFor(viewSpan, gw);
  final double blockPx = blockSize * gw / viewSpan;

  return cache.paint(
    canvas,
    configKey: [...activeChannels, ...keyExtras],
    gw: gw,
    gh: gh,
    dpr: dpr,
    viewStart: viewStart,
    viewSpan: viewSpan,
    yMin: yMin,
    yMax: yMax,
    totalSamples: totalSamples,
    // The recorded polyline overshoots a segment's edges by up to one
    // block (the join to the neighbor), and one block can be many px when
    // zoomed in past 1 sample/px -- the horizontal pad must cover it.
    hPad: math.max(kSegmentImagePad, blockPx + 2),
    vPad: kSegmentImagePad,
    // Gaps (live edge, bake backlog after pans/zooms) are always drawn as
    // vectors; with the bucket-accelerated reduction even history-wide gaps
    // are cheap enough to render directly.
    maxDirectGapPx: double.infinity,
    render: (cCanvas, start, end, texW) {
      // One block past the segment end joins the polyline to the next
      // segment; the envelope fill is clipped at the seam so the alpha
      // fills of adjacent segments never double-blend.
      final int limit = math.min(end + blockSize, totalSamples);

      // No data ink inside gaps: clip out their x-ranges so neither the
      // exact path's boundary blocks nor the bucket path's held-value line
      // can draw where no data exists (the hatching, drawn by the graph
      // chrome outside this layer, is the only marker there). Safe to apply
      // at bake time: gaps are append-only at the live edge, so the gap set
      // inside an already-baked segment can never change.
      final clip = _gapClipPath(data.gaps, start, limit, gw / viewSpan);
      if (clip != null) {
        cCanvas.save();
        cCanvas.clipPath(clip);
      }
      for (final ch in activeChannels) {
        if (data.channel(ch).data.isEmpty) continue;

        drawChannelEnvelope(
          cCanvas,
          color: getChannelColor(ch),
          graphW: gw,
          viewStart: start,
          viewSamples: viewSpan,
          totalSamples: limit,
          firstUsableSample: firstUsableSample,
          series: seriesFor(ch),
          valueToY: valueToY,
          clipEnvelopeSamples: end,
          avgStrokeWidth: avgStrokeWidth,
          avgAlpha: avgAlpha,
          envAlpha: envAlpha,
        );
      }
      if (clip != null) cCanvas.restore();
      // drawChannelEnvelope maps sample s to (s - start) * gw / viewSpan.
      return (end - start) * gw / viewSpan;
    },
  );
}

/// Everything-except-gaps clip for the sample window [start, end) under the
/// mapping `x = (s - start) * pxPerSample`, or null when no gap overlaps the
/// window (the common case; callers skip save/clip/restore entirely). Built
/// as one huge rect with even-odd gap holes; gap ranges are disjoint, so
/// even-odd punches each exactly once.
Path? _gapClipPath(GapList gaps, int start, int end, double pxPerSample) {
  if (gaps.isEmpty) return null;
  const double big = 1e9; // covers any pad/overdraw around the plot area
  Path? path;
  for (final (gs, ge) in gaps.rangesIn(start, end)) {
    path ??= Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(const Rect.fromLTRB(-big, -big, big, big));
    path.addRect(
      Rect.fromLTRB(
        (gs - start) * pxPerSample,
        -big,
        (ge - start) * pxPerSample,
        big,
      ),
    );
  }
  return path;
}

// ---------------------------------------------------------------------------
// Windowed time-series graph painters (force, derivative)
// ---------------------------------------------------------------------------

/// Common painter prologue shared by the force and derivative graphs: translate
/// into the plot area, compute the plot [Size], draw the frame border, and
/// resolve the visible window.
///
/// Returns null when there is nothing to draw (degenerate size, too few
/// samples, or a degenerate window). [minSamples] is the smallest sample count
/// the graph needs (1 for force, 2 for the derivative's first difference).
typedef _GraphLayout = ({
  Size graphSz,
  int viewStart,
  int viewEnd,
  int viewSamples,
});

_GraphLayout? _setupGraphFrame(
  Canvas canvas,
  Size size,
  GraphDataSource data,
  GraphController ctrl, {
  required double topSpace,
  required double bottomSpace,
  required int minSamples,
  required Color frameColor,
}) {
  final pen = Paint()
    ..color = frameColor
    ..style = PaintingStyle.stroke;

  canvas.translate(kGraphLeftSpace, topSpace);
  final graphSz = Size(
    size.width - kGraphLeftSpace - kGraphRightSpace,
    size.height - bottomSpace - topSpace,
  );

  if (graphSz.width <= 0 || graphSz.height <= 0) return null;

  canvas.drawRect(
    Rect.fromLTRB(0, 0, graphSz.width, graphSz.height),
    pen..strokeWidth = 0.5,
  );

  if (data.totalSamples < minSamples) return null;

  final (viewStart, viewEnd) = ctrl.effectiveRange(
    data.totalSamples,
    data.oldestSample,
    bufferCapacity: data.bufferCapacity,
  );
  final viewSamples = viewEnd - viewStart;
  if (viewSamples < minSamples) return null;

  return (
    graphSz: graphSz,
    viewStart: viewStart,
    viewEnd: viewEnd,
    viewSamples: viewSamples,
  );
}

/// Shared engine for the windowed time-series graphs (force, derivative).
///
/// Handles the pipeline common to both: frame setup, Y-range for the visible
/// window, axes/grid, zero baseline, missing-data hatching, and the
/// segment-cached envelope rendering. Subclasses define the series being
/// plotted -- [series] (per-channel [EnvelopeSeries]), [computeYRange],
/// [yTickLabel] -- plus layout tweaks and cache-key extras.
abstract class _TimeSeriesGraphPainter extends CustomPainter {
  final GraphDataSource _data;
  final AppSettings _settings;
  final GraphController _ctrl;

  /// Indices of the channels to plot (per-view; see [GraphWorkspace]).
  final List<int> _activeChannels;
  final SegmentedGraphCache cache;
  final ColorScheme colorScheme;

  /// Device pixel ratio used when rasterizing segment textures.
  final double dpr;

  /// Asks the host widget to schedule another frame; called when bake work
  /// remains so the rolling bakes complete even for static sources whose
  /// [GraphDataSource.repaint] never fires.
  final VoidCallback _requestRepaint;

  _TimeSeriesGraphPainter(
    this._data,
    this._settings,
    this._ctrl, {
    required List<int> activeChannels,
    required this.cache,
    required this.colorScheme,
    required this.dpr,
    required Listenable bakePump,
    required VoidCallback requestRepaint,
  }) : _activeChannels = activeChannels,
       _requestRepaint = requestRepaint,
       super(repaint: Listenable.merge([_data.repaint, _ctrl, bakePump]));

  // --- Layout hooks --------------------------------------------------------

  /// Padding above the plot area.
  double get topSpace;

  /// Whether to draw time labels below the X axis.
  bool get showXLabels => true;

  /// Whether to add half-delta minor grid lines on both axes.
  bool get drawMinorGrid => false;

  /// Offset from [GraphDataSource.oldestSample] of the first sample the
  /// series can be evaluated at (1 for a first difference).
  int get firstSampleOffset => 0;

  // --- Series hooks --------------------------------------------------------

  /// Returns the rendering recipe for [channel]: the per-sample evaluator
  /// (value at an absolute sample index, in display units; NaN marks a
  /// missing sample) plus optional bucket acceleration (see
  /// [EnvelopeSeries.bucketed] for the invariants it must satisfy).
  EnvelopeSeries series(int channel);

  /// Y-axis range (display units) for the visible window.
  YAxisRange computeYRange(int viewStart, int viewEnd);

  /// Label for a Y-axis tick.
  String yTickLabel(double tick);

  /// Per-channel values mixed into the segment-cache key; return the tares
  /// when the series depends on them.
  List<double> cacheKeyTares() => const [];

  /// Optional chrome drawn after the axes, before the data lines.
  void drawOverlay(Canvas canvas, Size graphSz) {}

  @override
  void paint(Canvas canvas, Size size) {
    final layout = _setupGraphFrame(
      canvas,
      size,
      _data,
      _ctrl,
      topSpace: topSpace,
      bottomSpace: showXLabels ? kGraphBottomSpace : 4,
      minSamples: 1 + firstSampleOffset,
      frameColor: colorScheme.primary.withAlpha(150),
    );
    if (layout == null) return;

    final graphSz = layout.graphSz;
    final viewStart = layout.viewStart;
    final viewEnd = layout.viewEnd;
    final viewSamples = layout.viewSamples;

    final activeIndices = _activeChannels;
    final oldestSample = _data.oldestSample;

    final yRange = computeYRange(viewStart, viewEnd);

    // Map a value in display units to Y pixel
    double valueToY(double val) {
      return graphSz.height -
          (val - yRange.yMin) * graphSz.height / (yRange.yMax - yRange.yMin);
    }

    // -- Grid and labels --
    final grid = Path();
    drawTimeAxis(
      canvas,
      grid,
      graphSz,
      viewStart: viewStart,
      viewEnd: viewEnd,
      sampleRate: _data.sampleRate,
      showLabels: showXLabels,
      drawMinor: drawMinorGrid,
      textColor: colorScheme.onSurface,
    );
    drawValueAxis(
      canvas,
      grid,
      graphSz,
      yRange,
      valueToY,
      labelFor: yTickLabel,
      drawMinor: drawMinorGrid,
      textColor: colorScheme.onSurface,
    );
    final gridPen = Paint()
      ..color = colorScheme.onSurface.withAlpha(50)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.2;
    canvas.drawPath(grid, gridPen);

    drawZeroBaseline(
      canvas,
      graphSz,
      yRange,
      valueToY,
      colorScheme.onSurface.withAlpha(130),
    );

    drawMissingDataHatching(
      canvas,
      graphSz,
      viewStart: viewStart,
      viewEnd: viewEnd,
      data: _data,
      color: colorScheme.error,
    );

    drawOverlay(canvas, graphSz);

    // -- Data lines (segment-cached envelope) --
    final workRemains = paintEnvelopeDataLayer(
      canvas,
      cache: cache,
      data: _data,
      activeChannels: activeIndices,
      keyExtras: [
        ...cacheKeyTares(),
        _settings.displayUnit,
        _data.calibrationSlope,
      ],
      gw: graphSz.width,
      gh: graphSz.height,
      dpr: dpr,
      viewStart: viewStart,
      viewSpan: viewSamples,
      yMin: yRange.yMin,
      yMax: yRange.yMax,
      firstUsableSample: oldestSample + firstSampleOffset,
      seriesFor: series,
    );
    if (workRemains) _requestRepaint();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Force graph: each channel's tared value in the selected display unit.
class ForceGraphPainter extends _TimeSeriesGraphPainter {
  @override
  final bool showXLabels;

  ForceGraphPainter(
    super.data,
    super.settings,
    super.ctrl, {
    this.showXLabels = true,
    required super.activeChannels,
    required super.cache,
    required super.colorScheme,
    required super.dpr,
    required super.bakePump,
    required super.requestRepaint,
  });

  @override
  double get topSpace => 4;

  @override
  bool get drawMinorGrid => true;

  @override
  List<double> cacheKeyTares() =>
      _activeChannels.map((ch) => _data.channel(ch).tare).toList();

  @override
  EnvelopeSeries series(int channel) => EnvelopeSeries.bucketed(
    sampleAt: taredDisplaySampleAt(_data, channel, _settings.displayUnit),
    buckets: _data.channel(channel).buckets,
    rawToDisplay: taredDisplayFromRaw(_data, channel, _settings.displayUnit),
  );

  @override
  YAxisRange computeYRange(int viewStart, int viewEnd) {
    // Compute data min/max across active channels in visible window (raw,
    // tare-subtracted) so the noise floor stays a raw-count threshold, then
    // convert to display units. [windowedExtremes] folds full buckets from
    // the precomputed aggregates (exact for min/max) and per-sample scans
    // only the partial head/tail, so the cost is O(window / bucketSize).
    final oldestSample = _data.oldestSample;
    final totalSamples = _data.totalSamples;
    final bufferCap = _data.bufferCapacity;
    double rawMax = 0;
    double rawMin = 0;
    bool hasData = false;

    for (final ch in _activeChannels) {
      final s = _data.channel(ch);
      final line = s.data;
      if (line.isEmpty) continue;
      final sScanStart = math.max(viewStart, oldestSample);
      final sScanEnd = math.min(viewEnd, totalSamples);
      if (sScanStart >= sScanEnd) continue;

      // Gap samples hold a previous real value, so they can never extend
      // the range: no exclusion needed.
      final ext = windowedExtremes(
        s.buckets,
        sScanStart,
        sScanEnd,
        (i) => line[i % bufferCap].toDouble(),
      );
      if (ext == null) continue;
      final lo = ext.$1 - s.tare;
      final hi = ext.$2 - s.tare;
      if (!hasData || hi > rawMax) rawMax = hi;
      if (!hasData || lo < rawMin) rawMin = lo;
      hasData = true;
    }

    // Enforce a minimum visible range (noise floor) so the graph isn't degenerate
    const double noiseFloor = 10000; // raw counts
    if (rawMax - rawMin < noiseFloor) {
      final mid = (rawMax + rawMin) / 2;
      rawMax = mid + noiseFloor / 2;
      rawMin = mid - noiseFloor / 2;
    }

    final unit = _settings.displayUnit;
    return _computeYRange(
      unit.fromRaw(rawMin, _data.calibrationSlope),
      unit.fromRaw(rawMax, _data.calibrationSlope),
    );
  }

  @override
  String yTickLabel(double tick) =>
      _formatTickLabel(tick, _settings.displayUnit.symbol);
}

/// Derivative graph: the first difference of each channel, scaled to display
/// units per second.
class DerivativeGraphPainter extends _TimeSeriesGraphPainter {
  DerivativeGraphPainter(
    super.data,
    super.settings,
    super.ctrl, {
    required super.activeChannels,
    required super.cache,
    required super.colorScheme,
    required super.dpr,
    required super.bakePump,
    required super.requestRepaint,
  });

  @override
  double get topSpace => 2;

  @override
  int get firstSampleOffset => 1; // first difference needs sample j-1

  /// Per-sample first difference in raw counts. A held value on either side
  /// of the difference would fabricate a flat or spiking derivative; NaN
  /// marks gap edges instead, breaking the polyline.
  double Function(int j) _rawDiffAt(int channel) {
    final line = _data.channel(channel).data;
    final bufferCap = _data.bufferCapacity;
    final gaps = _data.gaps;
    return (j) {
      if (gaps.contains(j) || gaps.contains(j - 1)) return double.nan;
      return (line[j % bufferCap] - line[(j - 1) % bufferCap]).toDouble();
    };
  }

  /// Per-sample first difference in display units per second.
  double Function(int j) _sampleAt(int channel) {
    final rawDiff = _rawDiffAt(channel);
    final scale = _displayScale;
    return (j) => rawDiff(j) * scale; // NaN propagates
  }

  /// Raw-diff -> display-units-per-second multiplier.
  double get _displayScale =>
      _settings.displayUnit.multiplierFromRaw(_data.calibrationSlope) *
      _data.sampleRate;

  @override
  EnvelopeSeries series(int channel) {
    final sampleAt = _sampleAt(channel);
    final buckets = _data.diffBucketsFor(channel);
    if (buckets == null) return EnvelopeSeries.exact(sampleAt);
    final scale = _displayScale;
    return EnvelopeSeries.bucketed(
      sampleAt: sampleAt,
      buckets: buckets,
      rawToDisplay: (raw) => raw * scale,
    );
  }

  @override
  YAxisRange computeYRange(int viewStart, int viewEnd) {
    // Derivative min/max (display units) across the visible window.
    // [windowedExtremes] folds full buckets from the precomputed diff
    // aggregates (exact for min/max) and per-sample scans only the partial
    // head/tail, so the cost is O(window / bucketSize).
    double dMin = 0;
    double dMax = 0;
    bool first = true;
    final startI = math.max(viewStart, _data.oldestSample + 1);
    final endI = math.min(viewEnd, _data.totalSamples);
    final scale = _displayScale;

    void fold(double d) {
      if (first || d < dMin) dMin = d;
      if (first || d > dMax) dMax = d;
      first = false;
    }

    for (final ch in _activeChannels) {
      if (_data.channel(ch).data.isEmpty) continue;
      if (startI >= endI) continue;

      final buckets = _data.diffBucketsFor(ch);
      if (buckets == null) {
        // Exact-only fallback for sources without diff aggregates.
        final valueAt = _sampleAt(ch);
        for (int i = startI; i < endI; i++) {
          final d = valueAt(i);
          if (!d.isNaN) fold(d);
        }
        continue;
      }

      final ext = windowedExtremes(buckets, startI, endI, _rawDiffAt(ch));
      if (ext == null) continue;
      // Folding both scaled bounds keeps this correct under a negative scale.
      fold(ext.$1 * scale);
      fold(ext.$2 * scale);
    }
    return _computeYRange(dMin, dMax);
  }

  @override
  String yTickLabel(double tick) => '${_formatTickValue(tick)}/s';

  @override
  void drawOverlay(Canvas canvas, Size graphSz) {
    // "dF/dt" label in top-left
    final dLabel = _prepareLabel(
      'dF/dt (${_settings.displayUnit.symbol}/s)',
      color: colorScheme.onSurface.withAlpha(150),
    );
    canvas.drawParagraph(dLabel, const Offset(4, 2));
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Format a tick value with appropriate precision.
String _formatTickLabel(double value, String unitSymbol) {
  final formatted = _formatTickValue(value);
  return '$formatted $unitSymbol';
}

String _formatTickValue(double value) {
  if (value == 0) return '0';
  final abs = value.abs();
  if (abs >= 100) return value.toStringAsFixed(0);
  if (abs >= 1) return value.toStringAsFixed(1);
  if (abs >= 0.1) return value.toStringAsFixed(2);
  return value.toStringAsFixed(3);
}

/// Return a "nice" number close to [value] for axis step sizes.
double _niceNum(double value) {
  if (value <= 0) return 1;
  final exp = (math.log(value) / math.ln10).floor();
  final frac = value / math.pow(10, exp);
  double nice;
  if (frac < 1.5) {
    nice = 1;
  } else if (frac < 3.5) {
    nice = 2;
  } else if (frac < 7.5) {
    nice = 5;
  } else {
    nice = 10;
  }
  return nice * math.pow(10, exp);
}
