import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// Image baking
// ---------------------------------------------------------------------------

/// Record [draw] and rasterize it into a [widthPx] x [heightPx]
/// physical-pixel [ui.Image]. The canvas is pre-scaled by [dpr] so [draw]
/// works in logical pixels.
ui.Image _bakeImage(
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
//                translations;
//   * squeeze -- the window spans the whole growing history: blits get a
//                corrective affine transform (both axis mappings are affine).
//
// Vector-redrawing the whole plot every frame caused low framerates.
// Web has no engine raster cache: a ui.Picture re-executes on Skia every
// frame. Immutable sample ranges are baked once into GPU ui.Images and
// blitted; rebakes are smeared across frames at [kSegmentBakeBudget] per
// frame. A steady frame rate is preferred over fast refill: a burst of
// work in one frame shows up as a stutter. A segment that cannot blit
// (see [SegmentedGraphCache._isBlittable]) draws nothing and refills only
// via the sweep; genuinely uncovered ranges (live-edge sliver, pan/zoom
// exposures) are the only full vector-draw paths.
//
// Config changes split by kind. Plot height, dpr, channel add/remove are
// pure drift: old segments keep blitting (ghosts/shifts) while the sweep
// re-bakes them rightmost-first (freshest data converges first). Tares ride
// the destructive key with unit/calibration instead: one segment composites
// every channel, so no single blit correction can hold per-channel shifts.
// On any config bump, segments outside the view are disposed so stale
// content cannot resurrect on a later pan.
//
// Quality invariant: a texture is only ever a vector render, never
// resampled from another texture.
//
// Live-edge invariant: segments never end past a bake horizon
// (SegmentViewConfig.bakeableSamples) that excludes the filling block and
// horizon zone at the data edge; both vector-draw every frame instead.
// ---------------------------------------------------------------------------

/// Target on-screen width (logical px) of one baked segment texture.
const double kSegmentTargetPx = 200;

/// Max relative scale drift (horizontal or vertical) a visible segment may
/// accumulate before its rolling re-render. 0.08 is an educated guess:
/// unbounded drift visibly smears, but the acceptable range is wide; loose
/// enough that the [kSegmentBakeBudget]-per-frame sweep keeps up.
const double kMaxSegmentDrift = 0.08;

/// Nominal baked line height (stroke + AA, logical px): the constant term
/// the corrective vertical blit stretch multiplies (see
/// [SegmentedGraphCache._isBlittable]).
const double kBakedLinePx = 2.0;

/// Max fraction of the plot height a vertically stretched baked line may
/// occupy before the segment's blit is suppressed (see
/// [SegmentedGraphCache._isBlittable]): past it, the stretch -- e.g. a
/// channel switch-off collapsing the Y-range onto a quiet channel -- reads
/// as a screen-filling smear, and the range draws nothing until re-baked.
const double kMaxBlitLineFraction = 0.25;

/// Min on-screen width (logical px) of an uncovered range before a bake is
/// spent on it. Narrower gaps -- e.g. the live-edge sliver -- are drawn as
/// vectors every frame until they outgrow this.
const double kSegmentGapBakePx = 40;

/// Segment (re)bakes allowed per frame. Each is a UI-thread toImageSync;
/// 1 prioritizes smearing rebakes across frames over quickly refilling
/// after zooms/jumps (see the file header).
const int kSegmentBakeBudget = 1;

/// Cached segments more than this many target-widths outside the view are
/// evicted; a segment is kSegmentTargetPx * dpr * plotHeight * dpr * 4 bytes
/// (a few MB on a tall graph at dpr 2), so the cache cannot be unbounded.
const int kSegmentEvictionMargin = 8;

/// [FilterQuality.none] showed gaps and seams in testing; bilinear does
/// not.
const FilterQuality kSegmentFilterQuality = FilterQuality.low;

/// Base padding (logical px) baked around a segment texture so AA stroke
/// bleed survives the image crop. Renderers that overshoot the segment
/// bounds (the graphs' one-block polyline join) pass a larger horizontal pad.
const double kSegmentImagePad = 4;

/// Renders samples [start, end) mapped to x in [0, ~texW) at the plot's
/// current y-mapping. Called both to bake segment textures and to draw
/// uncovered gaps directly to the frame canvas. Returns the logical px the
/// content occupies (x in [0, contentW) after the hPad translate); the
/// blit's x-scale reference. At most the allocated texW.
typedef SegmentRenderer =
    double Function(Canvas canvas, int start, int end, int texW);

/// One frame of inputs for [SegmentedGraphCache.paint]: the plot geometry
/// (gw x gh logical px at dpr; samples viewStart..viewStart+viewSpan mapped
/// to x in [0, gw), values yMin..yMax mapped to the height), the data/config
/// identity (generation + keys; see the staleness model on
/// [SegmentedGraphCache]), the sample domain and bake horizon
/// (totalSamples, bakeableSamples; see the live-edge invariant in the file
/// header), texture padding (hPad, vPad), and the vector renderer.
typedef SegmentViewConfig = ({
  int generation,
  List<Object?> destructiveKey,
  List<Object?> remapKey,
  double gw,
  double gh,
  double dpr,
  double viewStart,
  double viewSpan,
  double yMin,
  double yMax,
  int totalSamples,
  int bakeableSamples,
  double hPad,
  double vPad,
  SegmentRenderer render,
});

/// Everything one (re)bake needs: the frame config plus the quantities
/// [_maintain] derives from it once, so the bakes and the raster half read
/// the same derived values.
typedef _BakeEnv = ({
  SegmentViewConfig c,
  double pps,
  int viewStart,
  int viewEnd,
  int targetSpan,
});

/// One baked segment: an immutable vector render of samples [start, end)
/// plus the mapping and config it was baked under.
@immutable
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

  /// Plot height and pixel ratio at bake. The blit corrects for both
  /// (affine), so a change is pure resampling drift -- remap staleness,
  /// never invalidation.
  final double gh;
  final double dpr;

  /// Config keys at bake, compared against the cache's current ones:
  /// [destructiveKey] (unit, calibration, tares) -- a mismatch means the
  /// content is wrong in kind or place and must never blit; [remapKey]
  /// (channels) -- a mismatch leaves it approximately right (a ghost) and
  /// blittable until the rolling sweep replaces it.
  final List<Object?> destructiveKey;
  final List<Object?> remapKey;

  /// Padding baked around the content (AA bleed / polyline overshoot).
  final double hPad;
  final double vPad;

  const GraphSegment({
    required this.image,
    required this.start,
    required this.end,
    required this.contentW,
    required this.yMin,
    required this.yMax,
    required this.gh,
    required this.dpr,
    required this.destructiveKey,
    required this.remapKey,
    required this.hPad,
    required this.vPad,
  });

  void dispose() => image.dispose();
}

/// One refresh outcome: replace `_segments[from].._segments[to]` (inclusive)
/// with a single bake of [start, end). A no-op refresh is the identity plan:
/// [from] == [to], [start] == the segment's own start, [end] == its own
/// (horizon-clamped) end. See [SegmentedGraphCache._planRefresh].
typedef _RefreshPlan = ({int from, int to, int start, int end});

class SegmentedGraphCache {
  /// Baked segments ordered by [GraphSegment.start]. Segments never overlap
  /// (asserted in [_maintain]): a refresh only ever retracts to the bake
  /// horizon, swallows abutting neighbors, or stops at the next segment's
  /// start ([_planRefresh]), so the list is a disjoint tiling of the covered
  /// ranges. Ranges between segments are gaps: vector-drawn or left blank
  /// until a bake covers them.
  final List<GraphSegment> _segments = [];

  /// Current bake config; segments carry their own stamps. A destructiveKey
  /// mismatch suppresses the blit; a remapKey/gh/dpr mismatch keeps
  /// blitting (ghost/shift) and is swept. gh/dpr are NOT destructive: the
  /// blit affine corrects for both. [_generation] identifies the data
  /// stream itself; a change clears everything.
  int _generation = -1;
  double _gh = -1;
  double _dpr = -1;
  List<Object?> _destructiveKey = const [];
  List<Object?> _remapKey = const [];

  void clear() {
    for (final s in _segments) {
      s.dispose();
    }
    _segments.clear();
  }

  void dispose() => clear();

  /// Adopt [c]'s config as the cache's current stamps (see [_configDiffers]).
  void _stampConfig(SegmentViewConfig c) {
    _gh = c.gh;
    _dpr = c.dpr;
    _destructiveKey = List.of(c.destructiveKey);
    _remapKey = List.of(c.remapKey);
  }

  /// Whether the given config stamps differ from the cache's current ones.
  /// One check, two candidates: the frame config (a bump disposes out-of-view
  /// segments in [_maintain]) and a segment's bake stamps (a mismatch marks
  /// the segment for the rolling re-bake in [_stalePlan]).
  bool _configDiffers(
    List<Object?> destructiveKey,
    List<Object?> remapKey,
    double gh,
    double dpr,
  ) =>
      !listEquals(destructiveKey, _destructiveKey) ||
      !listEquals(remapKey, _remapKey) ||
      (gh - _gh).abs() > 0.1 ||
      dpr != _dpr;

  /// Bring the cache up to date for the frame [c] and blit it: apply
  /// generation/config changes, evict segments far outside the view, spend
  /// up to [kSegmentBakeBudget] segment (re)bakes, then blit the cached
  /// segments for the window and vector-draw the uncovered gaps up to
  /// totalSamples.
  ///
  /// Config identity is split in three (see the file header for the model):
  /// generation clears the cache on change; destructiveKey (unit,
  /// calibration, tares) suppresses blitting of mismatched segments;
  /// remapKey (channels) keeps them blitting. Both kinds of mismatch are
  /// re-baked by the rolling rightmost-first sweep at the bake budget, so a
  /// config change never costs more than one bake per call.
  ///
  /// bakeableSamples caps segment coverage: no bake ever ends past it. See
  /// the live-edge invariant in the file header; renderers pass the data
  /// edge minus the join slack needed to make their join block final (the
  /// envelope layer's join block past a segment end: up to two block sizes,
  /// see joinBlockEnd in graph_components.dart).
  ///
  /// Returns true when a bake happened this frame; the owner should then
  /// schedule another frame so rolling bakes continue (static sources never
  /// fire repaint on their own).
  @useResult
  bool paint(Canvas canvas, SegmentViewConfig c) {
    final (env, baked) = _maintain(c);
    _blitSegments(canvas, env);
    _drawGaps(canvas, env);
    return baked;
  }

  /// The maintenance half of [paint]: everything except the raster. Returns
  /// the frame's derived quantities alongside whether a bake happened, so the
  /// raster half reads exactly the values the bakes were made with.
  (_BakeEnv, bool) _maintain(SegmentViewConfig c) {
    final double pps = c.gw / c.viewSpan; // logical px per sample
    final double viewEnd = c.viewStart + c.viewSpan;
    final int targetSpan = math.max(1, (kSegmentTargetPx / pps).round());
    // Coverage bookkeeping is integer: bakes and gap ranges are
    // sample-aligned (block anchoring). The fractional scroll offset only
    // shifts blit placement, in [_blitSegments].
    final int covStart = c.viewStart.floor();
    final int covEnd = viewEnd.ceil();

    if (c.generation != _generation) {
      clear();
      _generation = c.generation;
      _stampConfig(c);
    } else if (_configDiffers(c.destructiveKey, c.remapKey, c.gh, c.dpr)) {
      // Config bump: dispose stale segments outside the view, so they cannot
      // resurrect on a later pan before the sweep reaches them. Disposed
      // ranges vector-draw if panned back to.
      _segments.removeWhere((s) {
        if (s.end > covStart && s.start < covEnd) return false;
        s.dispose();
        return true;
      });
      _stampConfig(c);
    }

    final env = (
      c: c,
      pps: pps,
      viewStart: covStart,
      viewEnd: covEnd,
      targetSpan: targetSpan,
    );

    final int margin = kSegmentEvictionMargin * targetSpan;
    _segments.removeWhere((s) {
      if (s.end >= covStart - margin && s.start <= covEnd + margin) {
        return false;
      }
      s.dispose();
      return true;
    });

    bool baked = false;
    for (int i = 0; i < kSegmentBakeBudget; i++) {
      if (!_bakeOne(env)) {
        break;
      }
      baked = true;
    }

    assert(_segmentsAreDisjoint());
    return (env, baked);
  }

  /// Debug-only invariant check: [_segments] is ordered by [GraphSegment.start]
  /// with no overlaps (gaps are fine). Every mutation path ends here via
  /// [_maintain].
  bool _segmentsAreDisjoint() {
    for (int k = 1; k < _segments.length; k++) {
      if (_segments[k - 1].end > _segments[k].start) return false;
    }
    return true;
  }

  /// Uncovered sub-ranges of [viewStart, min(viewEnd, totalSamples)).
  /// Coverage is purely geometric: a segment counts as covered even when it
  /// may not blit (its pixels draw nothing — see the file header).
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
  ///   1. the widest visible gap past [kSegmentGapBakePx];
  ///   2. the rightmost visible stale segment (see [_isStale]).
  /// Returns whether a bake happened.
  bool _bakeOne(_BakeEnv env) =>
      _bakeWidestGap(env) || _refreshStaleSegment(env);

  /// Priority 1: bake the widest uncovered gap past the threshold, right
  /// aligned: a bake is paid back per frame the range stays in view, and in
  /// a moving window (live follow, pans) the left side exits first. Also, under
  /// a sustained arrival rate above the bake budget, left alignment spends
  /// every bake at the exiting edge while the whole window vector-draws.
  /// Gaps up to one target span get the same range under either alignment
  /// (the common case), so only over-wide gaps change fill order:
  /// rightmost-first, matching the config sweep (freshest data converges
  /// first). A remainder left of the bake too narrow to ever re-cross the
  /// threshold is swallowed into the bake: unlike a leftover at the data
  /// edge, which arrival grows back to the threshold by itself, one abutting
  /// existing coverage would vector-draw forever. Left neighbors are
  /// absorbed while the merged bake stays within one target width, so the
  /// live-edge segment grows in place (one bake per sliver) instead of
  /// accumulating sliver-wide strips.
  bool _bakeWidestGap(_BakeEnv env) {
    (int, int)? bakeGap;
    double widestPx = kSegmentGapBakePx;
    for (final g in _gaps(env.viewStart, env.viewEnd, env.c.bakeableSamples)) {
      final double w = (g.$2 - g.$1) * env.pps;
      if (w > widestPx) {
        widestPx = w;
        bakeGap = g;
      }
    }
    if (bakeGap == null) return false;

    final int end = bakeGap.$2;
    int start = math.max(bakeGap.$1, end - env.targetSpan);
    if ((start - bakeGap.$1) * env.pps <= kSegmentGapBakePx) {
      start = bakeGap.$1; // swallow the orphaned remainder
    }
    assert(end > start); // non-empty gap and targetSpan >= 1 keep start < end
    assert(
      end <= env.c.bakeableSamples,
      'bake range end $end exceeds bake horizon ${env.c.bakeableSamples}',
    ); // _gaps caps domainEnd at the bake horizon

    // Insertion point: first segment starting inside/after the bake range.
    int at = 0;
    while (at < _segments.length && _segments[at].start < start) {
      at++;
    }
    // Absorb whole left neighbors while the merged bake stays within one
    // target width, so the live-edge segment grows in place (one bake per
    // sliver) instead of accumulating sliver-wide strips. [_splice] with an
    // empty right range is a plain insert.
    int from = at;
    while (from > 0 &&
        (end - _segments[from - 1].start) * env.pps <= kSegmentTargetPx) {
      from--;
    }
    if (from < at) start = _segments[from].start;

    _splice(from, at - 1, _bake(start, end, env));
    return true;
  }

  /// Priority 2: re-bake the rightmost visible stale segment (see
  /// [_stalePlan]), replacing the range [_planRefresh] computes.
  bool _refreshStaleSegment(_BakeEnv env) {
    for (int i = _segments.length - 1; i >= 0; i--) {
      final s = _segments[i];
      if (s.end <= env.viewStart || s.start >= env.viewEnd) continue;
      final p = _stalePlan(i, env);
      if (p == null) continue;
      if (p.end <= p.start) {
        _segments.removeAt(i).dispose();
        continue;
      }
      _splice(p.from, p.to, _bake(p.start, p.end, env));
      return true;
    }
    return false;
  }

  /// Whether [s] may blit under the current Y-mapping: the destructive key
  /// must match, and the corrective vertical stretch must keep the baked
  /// line ([kBakedLinePx] at bake) within [kMaxBlitLineFraction] of the plot
  /// height. One-sided: shrinking only sharpens, but a large stretch -- e.g.
  /// the Y-range collapsing onto a quiet channel -- smears the segment's line
  /// across the screen. A suppressed segment is kept, not disposed: a
  /// Y-range snap-back makes it blittable again.
  bool _isBlittable(GraphSegment s, SegmentViewConfig c) {
    if (!listEquals(s.destructiveKey, _destructiveKey)) return false;
    return _blitYScale(s, c) * kBakedLinePx <= c.gh * kMaxBlitLineFraction;
  }

  /// The corrective vertical scale a blit of [s] applies: baked value-range
  /// drift times the plot-height ratio since the bake.
  static double _blitYScale(GraphSegment s, SegmentViewConfig c) =>
      (s.yMax - s.yMin) / (c.yMax - c.yMin) * (c.gh / s.gh);

  /// The refresh plan for [i] if it is stale, else null:
  ///   * config-stale -- baked under outdated keys/gh/dpr;
  ///   * drift-stale -- x- or y-scale drift past [kMaxSegmentDrift];
  ///   * size-stale -- past two targets on screen or under half a target,
  ///     AND [_planRefresh] would change the geometry. A size outlier whose
  ///     refresh can only reproduce its own range is left alone: re-baking
  ///     identical pixels every frame is a [BakePump]-fed busy loop (the
  ///     quiescence invariant -- every bake moves a boundary or updates
  ///     content, then the scan goes quiet).
  ///
  /// Config and drift staleness take whatever plan [_planRefresh] computes,
  /// including an absorbed left neighbor: two tiles that both need re-baking
  /// are cheaper merged into one bake than refreshed in two frames.
  _RefreshPlan? _stalePlan(int i, _BakeEnv env) {
    final s = _segments[i];
    final p = _planRefresh(i, env);
    if (_configDiffers(s.destructiveKey, s.remapKey, s.gh, s.dpr)) return p;
    final double w = (s.end - s.start) * env.pps;
    final double xScale = w / s.contentW;
    final double yScale = (s.yMax - s.yMin) / (env.c.yMax - env.c.yMin);
    if (math.max((1 - xScale).abs(), (1 - yScale).abs()) > kMaxSegmentDrift) {
      return p;
    }
    final bool sizeOutlier =
        w > 2 * kSegmentTargetPx || w < kSegmentTargetPx / 2;
    return sizeOutlier &&
            p !=
                (
                  from: i,
                  to: i,
                  start: s.start,
                  end: math.min(s.end, env.c.bakeableSamples),
                )
        ? p
        : null;
  }

  /// Where a refresh of [i] would bake and which segments it would replace
  /// (see [_RefreshPlan]), independent of why. Disjointness ([_segments])
  /// is what makes this a partition operation rather than range arithmetic:
  /// the refresh never crosses the next segment's start, and swallows
  /// neighbors only whole.
  ///
  ///   * Past the bake horizon: retract the end (the horizon can recede
  ///     under an old segment on block-size jumps); a segment starting at or
  ///     past it yields an empty plan -- the caller drops the segment.
  ///   * Past two targets on screen: split to the RIGHTMOST target span --
  ///     rightmost-first refinement like the sweep itself, and the left
  ///     remainder pairs with [_bakeWidestGap]'s right-aligned fill so the
  ///     hole refills marching left instead of stranding a sliver between
  ///     two tiles. The `end - targetSpan > s.start` clause is the progress
  ///     guard: at pps over ~200 px/sample the span hits its 1-sample floor
  ///     and cannot shrink the segment.
  ///   * Otherwise: swallow abutting LEFT neighbors while the merged width
  ///     stays within 1.5 targets. Left, because the sweep runs
  ///     rightmost-first -- those neighbors are the still-stale ones, so one
  ///     bake replaces several stale tiles instead of one. 1.5 targets, not
  ///     the 2-target split cap: a merged tile needs headroom below the
  ///     split threshold or the next mild zoom-in splits it again.
  ///   * Still under half a target after that: grow the end into UNCOVERED
  ///     room only (live-edge slack or a gap, capped by the next segment's
  ///     start and the horizon); and if still narrow with an abutting right
  ///     neighbor, swallow the neighbor whole under the same 1.5-target cap.
  ///
  /// Birth widths are then bounded: splits land at one target span (up to
  /// `pps/2` px off [kSegmentTargetPx] from the [targetSpan] rounding) and
  /// merges at 1.5 targets, so nothing is born already past a size
  /// threshold -- the birth side of the quiescence invariant.
  _RefreshPlan _planRefresh(int i, _BakeEnv env) {
    final int bakeable = env.c.bakeableSamples;
    final s = _segments[i];
    final int end = math.min(s.end, bakeable);
    if (end <= s.start) {
      return (from: i, to: i, start: s.start, end: end);
    }
    if ((end - s.start) * env.pps > 2 * kSegmentTargetPx &&
        end - env.targetSpan > s.start) {
      return (from: i, to: i, start: end - env.targetSpan, end: end);
    }
    int from = i;
    int start = s.start;
    while (from > 0 &&
        _segments[from - 1].end == start &&
        (end - _segments[from - 1].start) * env.pps <= 1.5 * kSegmentTargetPx) {
      from--;
      start = _segments[from].start;
    }
    int mergedEnd = end;
    int to = i;
    if ((mergedEnd - start) * env.pps < kSegmentTargetPx / 2) {
      final int uncoveredLimit = math.min(
        to + 1 < _segments.length ? _segments[to + 1].start : bakeable,
        bakeable,
      );
      mergedEnd = math.max(
        mergedEnd,
        math.min(start + env.targetSpan, uncoveredLimit),
      );
      if ((mergedEnd - start) * env.pps < kSegmentTargetPx / 2 &&
          to + 1 < _segments.length &&
          _segments[to + 1].start == mergedEnd &&
          (_segments[to + 1].end - start) * env.pps <= 1.5 * kSegmentTargetPx) {
        to++;
        mergedEnd = _segments[to].end;
      }
    }
    return (from: from, to: to, start: start, end: mergedEnd);
  }

  /// Replace `_segments[from].._segments[to]` (inclusive) with [seg]; an empty
  /// range (`to < from`) is a plain insert at [from].
  void _splice(int from, int to, GraphSegment seg) {
    for (int k = from; k <= to; k++) {
      _segments[k].dispose();
    }
    _segments.replaceRange(from, to + 1, [seg]);
  }

  /// Vector-render samples [start, end) into a fresh texture sized to the
  /// range's current on-screen width, so its blit starts at scale ~1.
  GraphSegment _bake(int start, int end, _BakeEnv env) {
    final SegmentViewConfig c = env.c;
    final int texW = math.max(1, ((end - start) * env.pps).ceil());
    double contentW = texW.toDouble();
    final img = _bakeImage(
      ((texW + 2 * c.hPad) * c.dpr).ceil(),
      ((c.gh + 2 * c.vPad) * c.dpr).ceil(),
      c.dpr,
      (canvas) {
        canvas.translate(c.hPad, c.vPad);
        contentW = c.render(canvas, start, end, texW);
      },
    );
    return GraphSegment(
      image: img,
      start: start,
      end: end,
      contentW: math.max(contentW, 0.001),
      yMin: c.yMin,
      yMax: c.yMax,
      gh: c.gh,
      dpr: c.dpr,
      destructiveKey: _destructiveKey,
      remapKey: _remapKey,
      hPad: c.hPad,
      vPad: c.vPad,
    );
  }

  /// Blit every visible segment under the current mapping.
  ///
  /// Texture x-px u covers sample s = start + u * (end - start) / contentW,
  /// which today lands at x = (s - viewStart) * pps -- affine, so one
  /// drawImageRect repositions the content exactly. Vertically, content rows
  /// [0, s.gh] covered values [s.yMax, s.yMin] at bake; a valueToY of the
  /// form gh - (v - yMin) * gh / (yMax - yMin) is affine in (yMin, yMax), so
  /// a y scale+offset corrects for range changes AND for plot-height changes
  /// since the bake. Per-channel offsets (tares) are NOT corrected here:
  /// one segment composites every channel, so no single affine can hold
  /// per-channel shifts -- tares ride the destructive key instead.
  void _blitSegments(Canvas canvas, _BakeEnv env) {
    final SegmentViewConfig c = env.c;
    final double range = c.yMax - c.yMin;
    final paint = Paint()..filterQuality = kSegmentFilterQuality;
    for (final s in _segments) {
      if (!_isBlittable(s, c)) continue;
      final double x1 = (s.start - c.viewStart) * env.pps;
      final double x2 = (s.end - c.viewStart) * env.pps;
      // Segments are disjoint (see [_segments]), so one screen x has at most
      // one blit; the clip is just the view bounds.
      final double clipL = math.max(x1, 0.0);
      final double clipR = math.min(x2, c.gw);
      if (clipR <= clipL) continue;

      final double xs = (x2 - x1) / s.contentW;
      final double ys = _blitYScale(s, c);
      // Where the segment's top content row (value s.yMax) lands today.
      final double yTop = c.gh * (1 - (s.yMax - c.yMin) / range);

      canvas.save();
      canvas.clipRect(Rect.fromLTRB(clipL, -s.vPad, clipR, c.gh + s.vPad));
      canvas.drawImageRect(
        s.image,
        // Source is the CONTENT rect (content + pads), not the ceil'd image
        // bounds: the dead ceil column would otherwise bake a small scale
        // error into every blit, blurring even identity mappings.
        Rect.fromLTWH(
          0,
          0,
          (s.contentW + 2 * s.hPad) * s.dpr,
          (s.gh + 2 * s.vPad) * s.dpr,
        ),
        Rect.fromLTWH(
          x1 - s.hPad * xs,
          yTop - s.vPad * ys,
          (s.contentW + 2 * s.hPad) * xs,
          (s.gh + 2 * s.vPad) * ys,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  /// Vector-render the uncovered visible ranges (see the file header).
  void _drawGaps(Canvas canvas, _BakeEnv env) {
    final SegmentViewConfig c = env.c;
    for (final (gs, ge) in _gaps(env.viewStart, env.viewEnd, c.totalSamples)) {
      final double w = (ge - gs) * env.pps;
      final double x = (gs - c.viewStart) * env.pps;
      canvas.save();
      // The floored coverage start can put a gap's left edge up to one
      // sample-pixel left of the plot area; the translate keeps the content
      // mapping exact, so the clip is what gets clamped.
      canvas.clipRect(
        Rect.fromLTRB(
          math.max(x, 0.0),
          -c.vPad,
          math.min(x + w, c.gw),
          c.gh + c.vPad,
        ),
      );
      canvas.translate(x, 0);
      c.render(canvas, gs, ge, math.max(1, w.ceil()));
      canvas.restore();
    }
  }
}

// ---------------------------------------------------------------------------
// Bake pump (shared repaint driver for the rolling segment bake)
// ---------------------------------------------------------------------------

/// Repaint driver for the rolling segment bake: baking is rationed to
/// [kSegmentBakeBudget] per frame, so when work remains a painter calls
/// [schedule], which ticks listeners after the frame. Needed for static
/// sources (loaded sessions) whose GraphDataSource repaint never fires.
/// Owned and disposed by the host widget's State.
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
