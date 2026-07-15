import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/app_settings.dart';

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
      PerfStats.addSegmentBake(gap: true);
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
    PerfStats.addSegmentBake(gap: false);
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
      PerfStats.addSegmentDraw(blit: true);
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
      PerfStats.addSegmentDraw(blit: false);
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

/// A single channel's raw circular-buffer data plus its precomputed extremes
/// and tare offset. Returned by [GraphDataSource.channel].
typedef ChannelSeries = ({
  List<int> data,
  double min,
  double max,
  double tare,
  int bucketSize,
  Int32List bucketMins,
  Int32List bucketMaxs,
  Int32List bucketSums,
});

/// Data interface required by the shared graph components (main graph, minimap, etc).
/// This allows the components to render either live DataHub data or static SessionData.
///
/// Sources are not required to be [ChangeNotifier]s; instead they expose a
/// [repaint] [Listenable] that fires when their data changes (a never-firing
/// listenable is fine for static data). This keeps the interface usable by both
/// live and static sources, and leaves room for composed/derived sources later.
abstract interface class GraphDataSource {
  /// Total number of logical samples generated so far (can exceed bufferCapacity).
  int get totalSamples;

  /// The size of the circular buffer. Used to modulus array indices.
  int get bufferCapacity;

  /// The oldest available sample index (absolute time).
  int get oldestSample;

  /// The sample rate of the data (Hz).
  int get sampleRate;

  /// The calibration slope used to convert raw counts to kgf.
  double get calibrationSlope;

  /// Notifies listeners when the underlying data changes.
  Listenable get repaint;

  /// Returns the series (data + extremes + tare) for a given channel index.
  ChannelSeries channel(int channelIndex);

  /// The integer value representing a dropped/missing sample.
  /// The graph rendering will skip over these values and draw missing data hatchings.
  int? get missingSampleSentinel;
}

/// A [Listenable] that never fires; use as [GraphDataSource.repaint] for static
/// data sources (e.g. a loaded session).
final Listenable kNeverRepaints = _NeverListenable();

class _NeverListenable extends Listenable {
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

// ---------------------------------------------------------------------------
// Graph viewport controller (shared between force graph, derivative, minimap)
// ---------------------------------------------------------------------------

class GraphController extends ChangeNotifier {
  final int minLiveSpan;

  GraphController({this.minLiveSpan = 0})
    : _liveSpan = minLiveSpan > 0 ? minLiveSpan : null;

  /// Start of visible window in samples.
  int _viewStart = 0;
  int get viewStart => _viewStart;

  /// End of visible window in samples. Null means "follow live edge".
  int? _viewEnd;
  int? get viewEnd => _viewEnd;

  /// Whether we're following the live edge (auto-scroll with new data).
  bool _isLive = true;
  bool get isLive => _isLive;

  /// When in live mode and zoomed in, this is the fixed span to show
  /// from the right edge. Null means "show all data from _viewStart" (up to 10 minutes).
  int? _liveSpan;
  int? get liveSpan => _liveSpan;

  /// Snap to live mode -- follow the right edge.
  /// If [span] is provided, locks to that scrolling window.
  /// If not provided, it intelligently decides between full view or default scrolling window.
  void goLive({
    int? span,
    required int totalSamples,
    required int oldestSample,
  }) {
    if (span != null) {
      // Explicitly lock to a span (used by zoom out when it hits max)
      _liveSpan = span;
    } else if (_viewEnd != null) {
      final currentSpan = _viewEnd! - _viewStart;
      if (currentSpan < totalSamples - oldestSample) {
        // User is zoomed in to a specific window, lock to it
        _liveSpan = currentSpan;
      } else if (currentSpan > minLiveSpan) {
        // They zoomed out to see all available data (beyond minLiveSpan);
        // they want to see everything auto-expand.
        _liveSpan = null;
      } else {
        // They zoomed out, but we don't have much data yet. Lock to minimum
        // span so it cleanly starts scrolling once it hits 20s.
        _liveSpan = minLiveSpan;
      }
    }

    _isLive = true;
    _viewEnd = null;
    notifyListeners();
  }

  /// Set a specific visible window (exits live mode).
  void setWindow(int start, int end) {
    _viewStart = start;
    _viewEnd = end;
    _isLive = false;
    _liveSpan = null;
    notifyListeners();
  }

  /// Get the effective visible range given total data size.
  (int start, int end) effectiveRange(
    int totalSamples,
    int oldestSample, {
    int? bufferCapacity,
  }) {
    if (_isLive || _viewEnd == null) {
      final int maxSpan = math.max(minLiveSpan, totalSamples - oldestSample);
      int span = _liveSpan ?? maxSpan;
      if (bufferCapacity != null && span > bufferCapacity) {
        span = bufferCapacity;
      }
      return (totalSamples - span, totalSamples);
    }
    return (_viewStart, _viewEnd!.clamp(_viewStart + 1, totalSamples));
  }

  /// Whether the current window covers all available data.
  ///
  /// Every plot renders in one of two modes:
  ///   * squeeze -- the window spans the whole history, so the x-mapping of
  ///     every sample recompresses as new data arrives;
  ///   * slide   -- a fixed-span window slides over the data.
  bool isSqueeze(int totalSamples, int oldestSample) {
    final (s, e) = effectiveRange(totalSamples, oldestSample);
    return e - s >= totalSamples - oldestSample;
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
    if (newEnd >= totalSamples) {
      // Snap to live if the window reaches the right edge. goLive derives the
      // locked span from the window set here.
      _viewStart = newStart;
      _viewEnd = newEnd;
      goLive(totalSamples: totalSamples, oldestSample: oldestSample);
      return;
    }

    _viewStart = newStart;
    _viewEnd = newEnd;
    _isLive = false;
    _liveSpan = null;
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
      // hits max span means "show everything" (liveSpan = null, auto-expand).
      _viewStart = totalSamples - span; // Force right-align
      _viewEnd = totalSamples;
      goLive(
        span: span >= maxSpan ? null : span,
        totalSamples: totalSamples,
        oldestSample: oldestSample,
      );
      return;
    }

    _viewStart = newStart;
    _viewEnd = newEnd;
    _isLive = false;
    _liveSpan = null;
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
      anchorLiveEdge: _isLive,
      totalSamples: totalSamples,
      oldestSample: oldestSample,
    );
  }

  /// Reset to show all data in live mode (fully zoomed out).
  void reset() {
    _viewStart = 0;
    _viewEnd = null;
    _liveSpan = null;
    _isLive = true;
    notifyListeners();
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
// Minimap
// ---------------------------------------------------------------------------

class Minimap extends StatefulWidget {
  final GraphDataSource dataSource;
  final List<int> activeChannels;
  final GraphController graphCtrl;

  const Minimap({
    super.key,
    required this.dataSource,
    required this.activeChannels,
    required this.graphCtrl,
  });

  @override
  State<Minimap> createState() => _MinimapState();
}

class _MinimapState extends State<Minimap> {
  final SegmentedGraphCache _cache = SegmentedGraphCache();

  /// Extra repaint driver for the rolling bake: baking is rationed to one
  /// segment per frame, so when work remains the painter requests another
  /// frame via [_schedulePump]. Needed for static sources (loaded sessions)
  /// whose [GraphDataSource.repaint] never fires; harmless for live ones.
  final ValueNotifier<int> _bakePump = ValueNotifier<int>(0);
  bool _pumpScheduled = false;

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pumpScheduled = false;
      if (mounted) _bakePump.value++;
    });
  }

  @override
  void dispose() {
    _bakePump.dispose();
    _cache.dispose();
    super.dispose();
  }

  /// Span of the samples the minimap squeezes into its width.
  int _mapSpan(int totalSamples, int oldestSample) =>
      math.max(totalSamples - oldestSample, widget.graphCtrl.minLiveSpan);

  void _onMinimapTap(TapDownDetails d, double graphWidth) {
    final totalSamples = widget.dataSource.totalSamples;
    if (totalSamples == 0 || graphWidth <= 0) return;
    final oldestSample = widget.dataSource.oldestSample;
    final frac = ((d.localPosition.dx - kGraphLeftSpace) / graphWidth).clamp(
      0.0,
      1.0,
    );
    final mapSpan = _mapSpan(totalSamples, oldestSample);
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
    final samplesPerPixel = _mapSpan(totalSamples, oldestSample) / graphWidth;
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
                  widget.activeChannels,
                  widget.graphCtrl,
                  colorScheme,
                  dpr,
                  _cache,
                  _bakePump,
                  _schedulePump,
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
  final List<int> _activeIndices;
  final GraphController _ctrl;
  final ColorScheme _colorScheme;
  final double _dpr;
  final SegmentedGraphCache _cache;

  /// Asks the host widget to schedule another frame; called when bake work
  /// remains (rolling bootstrap / staleness passes) so it completes even for
  /// static sources whose [GraphDataSource.repaint] never fires.
  final VoidCallback _requestRepaint;

  _MinimapPainter(
    this._data,
    this._activeIndices,
    this._ctrl,
    this._colorScheme,
    this._dpr,
    this._cache,
    Listenable bakePump,
    this._requestRepaint,
  ) : super(repaint: Listenable.merge([_data.repaint, _ctrl, bakePump]));

  @override
  void paint(Canvas canvas, Size size) {
    // TEMP PERF: measure total minimap paint plus loop/draw split.
    final sw = Stopwatch()..start();
    final perf = EnvelopePerf();

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
    final mapSpan = math.max(totalSamples - oldestSample, _ctrl.minLiveSpan);
    final mapStart = totalSamples - mapSpan;

    // Compute global min/max (raw, tare-subtracted) for full data. The
    // +/-10000 floor keeps the range non-degenerate on flat data.
    double rawMax = 10000;
    double rawMin = -10000;
    for (final ch in _activeIndices) {
      final s = _data.channel(ch);
      final mx = s.max - s.tare;
      final mn = s.min - s.tare;
      if (mx > rawMax) rawMax = mx;
      if (mn < rawMin) rawMin = mn;
    }

    final tares = [for (final ch in _activeIndices) _data.channel(ch).tare];

    // Blit the cached segment textures under the current mapping, spend at
    // most one bake, and vector-draw the live-edge sliver. Gaps wider than
    // ~2 target widths (bootstrap / data jump) stay blank while the rolling
    // bakes fill the strip in.
    final workRemains = _cache.paint(
      canvas,
      configKey: [..._activeIndices, ...tares],
      gw: gw,
      gh: gh,
      dpr: _dpr,
      viewStart: mapStart,
      viewSpan: mapSpan,
      yMin: rawMin,
      yMax: rawMax,
      totalSamples: totalSamples,
      hPad: 0,
      vPad: 0,
      maxDirectGapPx: 2 * kSegmentTargetPx,
      render: (c, start, end, texW) {
        _drawWaveformColumns(
          c,
          texW,
          gh,
          start,
          end - start,
          rawMin,
          rawMax,
          tares,
          perf,
        );
        // drawSqueezedEnvelope spreads the range over exactly texW columns.
        return texW.toDouble();
      },
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

    PerfStats.addMinimapPaint(
      sw.elapsedMicroseconds,
      perf.loopMicros,
      perf.drawMicros,
    );
  }

  /// Vector-render samples [rangeStart, rangeStart + rangeSpan) as min/avg/
  /// max columns squeezed into [pixelWidth] columns. The [SegmentedGraphCache]
  /// renderer: used both to bake segment textures and to draw uncovered gaps
  /// (the live-edge sliver) directly to the frame canvas.
  void _drawWaveformColumns(
    Canvas canvas,
    int pixelWidth,
    double gh,
    int rangeStart,
    int rangeSpan,
    double rawMin,
    double rawMax,
    List<double> tares,
    EnvelopePerf perf,
  ) {
    final dataRange = rawMax - rawMin;
    for (int i = 0; i < _activeIndices.length; i++) {
      final ch = _activeIndices[i];
      final tare = tares[i];
      final chColor = getChannelColor(ch);

      drawSqueezedEnvelope(
        canvas,
        data: _data,
        channel: ch,
        pixelWidth: pixelWidth,
        rangeStart: rangeStart,
        rangeSpan: rangeSpan,
        valueToY: (raw) =>
            (gh - (raw - tare - rawMin) * gh / dataRange).clamp(0.0, gh),
        avgColor: chColor.withAlpha(180),
        envColor: chColor.withAlpha(60),
        perf: perf, // TEMP PERF
      );
    }
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
  final bool showDerivative;
  final bool isLiveGraph;
  final bool showEnvelope;
  final bool showMinimap;

  const GraphWorkspace({
    super.key,
    required this.data,
    required this.ctrl,
    required this.settings,
    this.showDerivative = false,
    this.isLiveGraph = true,
    this.showEnvelope = true,
    this.showMinimap = true,
  });

  @override
  State<GraphWorkspace> createState() => _GraphWorkspaceState();
}

class _GraphWorkspaceState extends State<GraphWorkspace> {
  final SegmentedGraphCache _forceCache = SegmentedGraphCache();
  final SegmentedGraphCache _derivCache = SegmentedGraphCache();

  /// Extra repaint driver for the rolling bake: baking is rationed to a few
  /// segments per frame, so when work remains a painter requests another
  /// frame via [_schedulePump]. Needed for static sources (loaded sessions)
  /// whose [GraphDataSource.repaint] never fires; harmless for live ones.
  final ValueNotifier<int> _bakePump = ValueNotifier<int>(0);
  bool _pumpScheduled = false;

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pumpScheduled = false;
      if (mounted) _bakePump.value++;
    });
  }

  @override
  void dispose() {
    _bakePump.dispose();
    _forceCache.dispose();
    _derivCache.dispose();
    super.dispose();
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
                        showXLabels: !widget.showDerivative,
                        showEnvelope: widget.showEnvelope,
                        cache: _forceCache,
                        colorScheme: colorScheme,
                        dpr: dpr,
                        bakePump: _bakePump,
                        requestRepaint: _schedulePump,
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
                          showEnvelope: widget.showEnvelope,
                          cache: _derivCache,
                          colorScheme: colorScheme,
                          dpr: dpr,
                          bakePump: _bakePump,
                          requestRepaint: _schedulePump,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                // Minimap
                if (widget.showMinimap)
                  Minimap(
                    dataSource: widget.data,
                    activeChannels: widget.settings.activeChannelIndices,
                    graphCtrl: widget.ctrl,
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
            // Zoom buttons
            Positioned(
              right: 72,
              bottom: 40,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'zoomIn_${widget.data.hashCode}',
                    onPressed: () {
                      if (widget.data.totalSamples > 0) {
                        final focal = widget.ctrl.isLive ? 1.0 : 0.5;
                        widget.ctrl.zoom(
                          1.2,
                          focal,
                          widget.data.totalSamples,
                          widget.data.oldestSample,
                          widget.data.bufferCapacity,
                        );
                      }
                    },
                    child: const Icon(Icons.zoom_in),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'zoomOut_${widget.data.hashCode}',
                    onPressed: () {
                      if (widget.data.totalSamples > 0) {
                        final focal = widget.ctrl.isLive ? 1.0 : 0.5;
                        widget.ctrl.zoom(
                          1 / 1.2,
                          focal,
                          widget.data.totalSamples,
                          widget.data.oldestSample,
                          widget.data.bufferCapacity,
                        );
                      }
                    },
                    child: const Icon(Icons.zoom_out),
                  ),
                ],
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

// Label paragraph cache
final Map<String, ui.Paragraph> _labelCache = HashMap();

ui.Paragraph _prepareLabel(String text, {Color color = Colors.black}) {
  final key = '$text|${color.toARGB32()}';
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

/// Draws a diagonal warning hatch pattern in regions where data is missing (sentinel value).
void drawMissingDataHatching(
  Canvas canvas,
  Size graphSz, {
  required int viewStart,
  required int viewEnd,
  required GraphDataSource data,
  required Color color,
}) {
  final sentinel = data.missingSampleSentinel;
  if (sentinel == null) return; // source can't have gaps: skip the scan

  final totalSamples = data.totalSamples;
  final oldestSample = data.oldestSample;
  final sScanStart = math.max(viewStart, oldestSample);
  final sScanEnd = math.min(viewEnd, totalSamples);
  if (sScanStart >= sScanEnd) return;

  // We only need to check channel 0 since dropped packets are dropped for all channels simultaneously.
  final line = data.channel(0).data;
  final bufferCap = data.bufferCapacity;

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

  int gapStart = -1;

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

  for (int i = sScanStart; i < sScanEnd; i++) {
    if (line[i % bufferCap] == sentinel) {
      if (gapStart == -1) {
        gapStart = i;
      }
    } else {
      if (gapStart != -1) {
        drawHatchRegion(gapStart, i);
        gapStart = -1;
      }
    }
  }

  if (gapStart != -1) {
    drawHatchRegion(gapStart, sScanEnd);
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

// TEMP PERF (remove after profiling): timing sink threaded through the
// squeeze-envelope renderer so the minimap can report reduction-loop time and
// canvas-draw time separately.
class EnvelopePerf {
  final Stopwatch sw = Stopwatch()..start();
  int loopMicros = 0;
  int drawMicros = 0;
}

/// The (average polyline, min/max envelope fill) [VertexBatcher] pair shared
/// by the envelope renderers. Both batchers reuse one [Paint], restyled per
/// flush.
({VertexBatcher avg, VertexBatcher env}) _envelopeBatchers(
  Canvas canvas, {
  required Color avgColor,
  required double avgStrokeWidth,
  required Color envColor,
  EnvelopePerf? perf,
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
      final start = perf?.sw.elapsedMicroseconds;
      canvas.drawRawPoints(ui.PointMode.polygon, view, pen);
      if (start != null) {
        perf!.drawMicros += perf.sw.elapsedMicroseconds - start;
      }
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
      final start = perf?.sw.elapsedMicroseconds;
      canvas.drawVertices(vertices, ui.BlendMode.srcOver, pen);
      if (start != null) {
        perf!.drawMicros += perf.sw.elapsedMicroseconds - start;
      }
      vertices.dispose();
    },
  );

  return (avg: avg, env: env);
}

/// Render one channel as a min/avg/max envelope across [graphW] pixel columns.
///
/// For each pixel column the samples mapped to it are reduced to min/avg/max via
/// [sampleAt] (raw per-sample value), then projected with [valueToY]. The shaded
/// envelope is filled at low alpha and the average is stroked on top.
///
/// Blocks are anchored to absolute sample indices so the geometry lands on
/// the same pixels regardless of scroll, which is what makes it segment-
/// cacheable; [drawSqueezedEnvelope] is the bucket-accelerated counterpart
/// used by the minimap.
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
  required double Function(int sampleIndex) sampleAt,
  required double Function(double rawReduced) valueToY,
  required int clipEnvelopeSamples,
  bool showEnvelope = true,
}) {
  final (avg: avg, env: env) = _envelopeBatchers(
    canvas,
    avgColor: color,
    avgStrokeWidth: 1.5,
    envColor: color.withAlpha(60),
  );

  // Calculate alignment block size
  final int blockSize = blockSizeFor(viewSamples, graphW);

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

    double total = 0;
    double minRaw = double.infinity;
    double maxRaw = double.negativeInfinity;
    int validSamples = 0;

    for (int j = drawStart; j < sEnd; j++) {
      final v = sampleAt(j);
      if (v.isNaN) continue;
      total += v;
      if (v < minRaw) minRaw = v;
      if (v > maxRaw) maxRaw = v;
      validSamples++;
    }

    if (validSamples == 0) {
      // Entire block is dropped samples. Break the polyline.
      if (showEnvelope) env.flush();
      avg.flush();
      continue;
    }

    final avgVal = total / validSamples;

    final avgY = valueToY(avgVal);
    final minY = valueToY(minRaw);
    final maxY = valueToY(maxRaw);

    // Absolute X (in this canvas's local space): a baked segment passes its
    // own start as viewStart, so xPos is segment-local and the segment slides
    // as a whole.
    final double xPos = (sStart - viewStart) * graphW / viewSamples;
    final double nextXPos = (sEnd - viewStart) * graphW / viewSamples;

    avg.add(xPos, avgY);

    if (showEnvelope && sStart < clipEnvelopeSamples) {
      env.add(xPos, maxY);
      env.add(xPos, minY);
      env.add(nextXPos, maxY);
      env.add(nextXPos, minY);

      if (env.wouldOverflow(8)) env.flush();
    }

    if (avg.wouldOverflow(2)) avg.flush();
  }

  if (showEnvelope) env.flush();
  avg.flush();
}

/// Render one channel as a min/avg/max envelope with one block per pixel
/// column, squeezing the sample range [rangeStart, rangeStart + rangeSpan)
/// into [pixelWidth] columns.
///
/// This is the bucket-accelerated counterpart of [drawChannelEnvelope], used
/// by the minimap. Columns spanning many samples aggregate from the channel's
/// precomputed bucket arrays; columns spanning few (zoomed in past ~2
/// buckets/column) loop the raw ring buffer to avoid blockiness.
///
/// Reduction happens in raw counts; [valueToY] projects a reduced raw value
/// (not tare-subtracted) to a pixel Y.
void drawSqueezedEnvelope(
  Canvas canvas, {
  required GraphDataSource data,
  required int channel,
  required int pixelWidth,
  required int rangeStart,
  required int rangeSpan,
  required double Function(double raw) valueToY,
  required Color avgColor,
  required Color envColor,
  double avgStrokeWidth = 1.0,
  EnvelopePerf? perf, // TEMP PERF
}) {
  final series = data.channel(channel);
  final line = series.data;
  if (line.isEmpty) return;

  final bufferCapacity = data.bufferCapacity;
  final totalSamples = data.totalSamples;
  final oldestSample = data.oldestSample;
  final sentinel = data.missingSampleSentinel;

  final (avg: avg, env: env) = _envelopeBatchers(
    canvas,
    avgColor: avgColor,
    avgStrokeWidth: avgStrokeWidth,
    envColor: envColor,
    perf: perf,
  );

  final int bucketSize = series.bucketSize;
  final bucketMins = series.bucketMins;
  final bucketMaxs = series.bucketMaxs;
  final bucketSums = series.bucketSums;
  final int numBuckets = bucketMins.length;

  for (int px = 0; px < pixelWidth; px++) {
    final int sStart = rangeStart + px * rangeSpan ~/ pixelWidth;
    final int sEnd = rangeStart + (px + 1) * rangeSpan ~/ pixelWidth;
    final int drawStart = math.max(sStart, oldestSample);
    final int drawEnd = math.min(sEnd, totalSamples);

    if (drawStart >= drawEnd) continue;

    double total = 0;
    double minRaw = double.infinity;
    double maxRaw = double.negativeInfinity;
    int validSamples = 0;

    final int samplesInPixel = drawEnd - drawStart;

    final loopStart = perf?.sw.elapsedMicroseconds; // TEMP PERF

    if (samplesInPixel <= bucketSize * 2) {
      // High-res mode: loop the raw array to avoid blockiness when zoomed
      // in. Honors the dropped-sample sentinel so gaps don't skew the plot.
      for (int j = drawStart; j < drawEnd; j++) {
        final val = line[j % bufferCapacity];
        if (sentinel != null && val == sentinel) {
          continue;
        }
        final valDouble = val.toDouble();
        total += valDouble;
        if (valDouble < minRaw) minRaw = valDouble;
        if (valDouble > maxRaw) maxRaw = valDouble;
        validSamples++;
      }
    } else {
      // Squished mode: aggregate from the precomputed bucket arrays.
      // Sentinels are already excluded from the buckets at ingest time.
      final int bStart = drawStart ~/ bucketSize;
      final int bEnd = drawEnd ~/ bucketSize;

      for (int b = bStart; b <= bEnd; b++) {
        final int listIdx = b % numBuckets;

        final double bMin = bucketMins[listIdx].toDouble();
        final double bMax = bucketMaxs[listIdx].toDouble();
        if (bMin < minRaw) minRaw = bMin;
        if (bMax > maxRaw) maxRaw = bMax;

        int count = bucketSize;
        if (b == bStart) {
          // Only count the covered portion of the first bucket.
          final int bucketEndSample = (b + 1) * bucketSize;
          count = bucketEndSample - drawStart;
          if (count > bucketSize) count = bucketSize;
        } else if (b == bEnd) {
          // Only count the covered portion of the last bucket.
          final int bucketStartSample = b * bucketSize;
          count = drawEnd - bucketStartSample;
          if (count > bucketSize) count = bucketSize;
        }
        if (count < 0) count = 0;

        // Approximate the sum contribution of the covered portion.
        final double avgOfBucket = bucketSums[listIdx] / bucketSize;
        total += avgOfBucket * count;
        validSamples += count;
      }
    }

    if (loopStart != null) {
      perf!.loopMicros += perf.sw.elapsedMicroseconds - loopStart; // TEMP PERF
    }

    if (validSamples == 0) {
      // Entire column is dropped samples. Break the polyline.
      env.flush();
      avg.flush();
      continue;
    }

    final avgY = valueToY(total / validSamples);
    final minY = valueToY(minRaw);
    final maxY = valueToY(maxRaw);

    final xPos = px.toDouble();
    avg.add(xPos, avgY);

    env.add(xPos, maxY);
    env.add(xPos, minY);

    // Flush chunks if we are getting close to the array limits
    if (env.wouldOverflow(4)) env.flush();
    if (avg.wouldOverflow(2)) avg.flush();
  }

  // Flush remaining data
  env.flush();
  avg.flush();
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

// ---------------------------------------------------------------------------
// TEMP PERF INSTRUMENTATION (remove after profiling)
//
// Aggregates two independent measurements and prints them together every
// [_reportEvery] frames:
//   * Dart paint time   -- time the UI thread spends in the time-series
//                          painters' paint (force + derivative) building the
//                          draw calls (recorded via [addPaint]).
//   * Skwasm raster time -- FrameTiming.rasterDuration, the worker/GPU thread
//                          time to execute the recorded display list.
//   * Build time         -- FrameTiming.buildDuration, for context.
// Frame timings are fed in via SchedulerBinding.addTimingsCallback (see
// _LiveTabState); the report is emitted from there once 60 frames accrue.
// ---------------------------------------------------------------------------
class PerfStats {
  static const int _reportEvery = 60;

  // Dart paint accumulation (UI thread).
  static int _paintCount = 0;
  static int _paintMicros = 0;

  static int _minimapCount = 0;
  static int _minimapMicros = 0;
  static int _minimapLoopMicros = 0;
  static int _minimapDrawMicros = 0;

  /// Record one _TimeSeriesGraphPainter.paint() duration.
  static void addPaint(int micros) {
    _paintMicros += micros;
    _paintCount++;
  }

  static void addMinimapPaint(int total, int loop, int draw) {
    _minimapCount++;
    _minimapMicros += total;
    _minimapLoopMicros += loop;
    _minimapDrawMicros += draw;
  }

  // Segment-cache accounting (shared by minimap, force, derivative).
  static int _segGapBakes = 0;
  static int _segRefreshBakes = 0;
  static int _segBlits = 0;
  static int _segDirect = 0;

  /// Record one segment bake: [gap] fills uncovered ranges (live-edge
  /// sliver, bootstrap, pan/zoom exposure) vs. staleness refreshes.
  static void addSegmentBake({required bool gap}) {
    if (gap) {
      _segGapBakes++;
    } else {
      _segRefreshBakes++;
    }
  }

  /// Record one segment draw: a texture [blit], or a gap vector-drawn
  /// directly to the frame canvas.
  static void addSegmentDraw({required bool blit}) {
    if (blit) {
      _segBlits++;
    } else {
      _segDirect++;
    }
  }

  /// Feed one frame's timing. Emits a combined report every 60 frames.
  static void addFrame(int rasterMicros, int buildMicros) {
    _rasterMicros += rasterMicros;
    _buildMicros += buildMicros;
    _frameCount++;
    if (_frameCount >= _reportEvery) _report();
  }

  static int _frameCount = 0;
  static int _rasterMicros = 0;
  static int _buildMicros = 0;

  static void _report() {
    final dartAvg = _paintCount > 0 ? _paintMicros / _paintCount : 0;
    final mmAvg = _minimapCount > 0 ? _minimapMicros / _minimapCount : 0;
    final mmLoopAvg = _minimapCount > 0
        ? _minimapLoopMicros / _minimapCount
        : 0;
    final mmDrawAvg = _minimapCount > 0
        ? _minimapDrawMicros / _minimapCount
        : 0;
    final rasterAvg = _frameCount > 0 ? _rasterMicros / _frameCount : 0;
    final buildAvg = _frameCount > 0 ? _buildMicros / _frameCount : 0;
    final fc = _frameCount > 0 ? _frameCount : 1;
    debugPrint(
      '[PERF] over $_frameCount frames | '
      'Main paint: ${dartAvg.toStringAsFixed(0)}us (${_paintCount}x) | '
      'Minimap: ${mmAvg.toStringAsFixed(0)}us (loop: ${mmLoopAvg.toStringAsFixed(0)}us, draw: ${mmDrawAvg.toStringAsFixed(0)}us) | '
      'segs/frame: ${(_segBlits / fc).toStringAsFixed(1)} blit, '
      '${(_segDirect / fc).toStringAsFixed(1)} direct | '
      'bakes: ${_segGapBakes}g+${_segRefreshBakes}r | '
      'Skwasm raster: ${rasterAvg.toStringAsFixed(0)}us | '
      'build: ${buildAvg.toStringAsFixed(0)}us',
    );
    _paintCount = 0;
    _paintMicros = 0;
    _minimapCount = 0;
    _minimapMicros = 0;
    _minimapLoopMicros = 0;
    _minimapDrawMicros = 0;
    _segGapBakes = 0;
    _segRefreshBakes = 0;
    _segBlits = 0;
    _segDirect = 0;
    _frameCount = 0;
    _rasterMicros = 0;
    _buildMicros = 0;
  }
}

/// Shared engine for the windowed time-series graphs (force, derivative).
///
/// Handles the pipeline common to both: frame setup, Y-range for the visible
/// window, axes/grid, zero baseline, missing-data hatching, and the
/// segment-cached envelope rendering. Subclasses define the series being
/// plotted -- [sampleAt] (per-channel value in display units), [computeYRange],
/// [yTickLabel] -- plus layout tweaks and cache-key extras.
abstract class _TimeSeriesGraphPainter extends CustomPainter {
  final GraphDataSource _data;
  final AppSettings _settings;
  final GraphController _ctrl;
  final bool showEnvelope;
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
    this.showEnvelope = true,
    required this.cache,
    required this.colorScheme,
    required this.dpr,
    required Listenable bakePump,
    required VoidCallback requestRepaint,
  }) : _requestRepaint = requestRepaint,
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

  /// Returns the series evaluator for [channel]: the value at an absolute
  /// sample index, in display units. NaN marks a missing sample.
  double Function(int j) sampleAt(int channel);

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
    // TEMP PERF: measure Dart-side draw-call construction time (UI thread).
    final sw = Stopwatch()..start();
    try {
      _paint(canvas, size);
    } finally {
      sw.stop();
      PerfStats.addPaint(sw.elapsedMicroseconds);
    }
  }

  void _paint(Canvas canvas, Size size) {
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

    final activeIndices = _settings.activeChannelIndices;
    final oldestSample = _data.oldestSample;
    final totalSamples = _data.totalSamples;

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
    final int blockSize = blockSizeFor(viewSamples, graphSz.width);
    final double blockPx = blockSize * graphSz.width / viewSamples;

    final workRemains = cache.paint(
      canvas,
      configKey: [
        ...activeIndices,
        ...cacheKeyTares(),
        _settings.displayUnit,
        _data.calibrationSlope,
        showEnvelope,
      ],
      gw: graphSz.width,
      gh: graphSz.height,
      dpr: dpr,
      viewStart: viewStart,
      viewSpan: viewSamples,
      yMin: yRange.yMin,
      yMax: yRange.yMax,
      totalSamples: totalSamples,
      // The recorded polyline overshoots a segment's edges by up to one
      // block (the join to the neighbor), and one block can be many px when
      // zoomed in past 1 sample/px -- the horizontal pad must cover it.
      hPad: math.max(kSegmentImagePad, blockPx + 2),
      vPad: kSegmentImagePad,
      // Gaps (live edge, bake backlog after pans/zooms) are always drawn as
      // vectors on the main plots; only the minimap blanks its big gaps.
      maxDirectGapPx: double.infinity,
      render: (cCanvas, start, end, texW) {
        // One block past the segment end joins the polyline to the next
        // segment; the envelope fill is clipped at the seam so the alpha
        // fills of adjacent segments never double-blend.
        final int limit = math.min(end + blockSize, totalSamples);
        for (final ch in activeIndices) {
          if (_data.channel(ch).data.isEmpty) continue;

          drawChannelEnvelope(
            cCanvas,
            color: getChannelColor(ch),
            graphW: graphSz.width,
            viewStart: start,
            viewSamples: viewSamples,
            totalSamples: limit,
            firstUsableSample: oldestSample + firstSampleOffset,
            sampleAt: sampleAt(ch),
            valueToY: (v) => valueToY(v).clamp(0.0, graphSz.height),
            showEnvelope: showEnvelope,
            clipEnvelopeSamples: end,
          );
        }
        // drawChannelEnvelope maps sample s to (s - start) * gw / viewSamples.
        return (end - start) * graphSz.width / viewSamples;
      },
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
    super.showEnvelope,
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
  List<double> cacheKeyTares() => _settings.activeChannelIndices
      .map((ch) => _data.channel(ch).tare)
      .toList();

  @override
  double Function(int j) sampleAt(int channel) {
    final s = _data.channel(channel);
    final line = s.data;
    final tare = s.tare;
    final bufferCap = _data.bufferCapacity;
    final sentinel = _data.missingSampleSentinel;
    final slopeToUnit = _settings.displayUnit.multiplierFromRaw(
      _data.calibrationSlope,
    );
    return (j) {
      final val = line[j % bufferCap];
      if (sentinel != null && val == sentinel) return double.nan;
      return (val - tare) * slopeToUnit;
    };
  }

  @override
  YAxisRange computeYRange(int viewStart, int viewEnd) {
    // Compute data min/max across active channels in visible window (raw,
    // tare-subtracted) so the noise floor stays a raw-count threshold, then
    // convert to display units.
    final oldestSample = _data.oldestSample;
    final totalSamples = _data.totalSamples;
    double rawMax = 0;
    double rawMin = 0;
    bool hasData = false;

    for (final ch in _settings.activeChannelIndices) {
      final s = _data.channel(ch);
      final line = s.data;
      if (line.isEmpty) continue;
      final tare = s.tare;
      final bufferCap = _data.bufferCapacity;
      final sentinel = _data.missingSampleSentinel;
      final sScanStart = math.max(viewStart, oldestSample);
      final sScanEnd = math.min(viewEnd, totalSamples);
      for (int i = sScanStart; i < sScanEnd; i++) {
        final rawVal = line[i % bufferCap];
        if (sentinel != null && rawVal == sentinel) continue;
        final v = rawVal - tare;
        if (!hasData || v > rawMax) rawMax = v.toDouble();
        if (!hasData || v < rawMin) rawMin = v.toDouble();
        hasData = true;
      }
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
    super.showEnvelope,
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

  @override
  double Function(int j) sampleAt(int channel) {
    final line = _data.channel(channel).data;
    final bufferCap = _data.bufferCapacity;
    final sentinel = _data.missingSampleSentinel;
    final scale =
        _settings.displayUnit.multiplierFromRaw(_data.calibrationSlope) *
        _data.sampleRate;
    return (j) {
      final v1 = line[j % bufferCap];
      final v2 = line[(j - 1) % bufferCap];
      if (sentinel != null && (v1 == sentinel || v2 == sentinel)) {
        return double.nan;
      }
      return (v1 - v2) * scale;
    };
  }

  @override
  YAxisRange computeYRange(int viewStart, int viewEnd) {
    // Compute derivative min/max (in display units) across the visible window.
    double dMin = 0;
    double dMax = 0;
    bool first = true;
    final startI = math.max(viewStart, _data.oldestSample + 1);
    final endI = math.min(viewEnd, _data.totalSamples);
    for (final ch in _settings.activeChannelIndices) {
      if (_data.channel(ch).data.isEmpty) continue;
      final valueAt = sampleAt(ch);
      for (int i = startI; i < endI; i++) {
        final d = valueAt(i);
        if (d.isNaN) continue;
        if (first) {
          dMin = d;
          dMax = d;
          first = false;
        } else {
          if (d < dMin) dMin = d;
          if (d > dMax) dMax = d;
        }
      }
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
