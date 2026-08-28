import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

// ---------------------------------------------------------------------------
// Image baking
// ---------------------------------------------------------------------------

/// Record [draw] and synchronously rasterize it into a [widthPx] x [heightPx]
/// physical-pixel [ui.Image]. The canvas is pre-scaled by [dpr] so [draw]
/// works in logical pixels.
///
/// This is the only place a [ui.Picture] appears in this file: `toImageSync`
/// requires one as an intermediate, so it is created and disposed here and
/// only the image escapes.
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
// Full re-renders are avoided. All changes should prefer to smear the rebake
// across multiple frames, and STALE content is never vector-redrawn: a
// segment that cannot blit ([SegmentedGraphCache._isBlittable]) draws
// NOTHING and refills only via the sweep (blank-then-refill, one segment
// per frame). Never extend the redraw set -- the per-frame raster budget is
// one segment of work, on web especially (no engine raster cache).
// Genuinely uncovered ranges ARE vector-drawn whole and are the only
// remaining full-redraw paths: the live-edge sliver, and bootstrap /
// zoom-out / pan exposures where no tile exists at all (tolerated as
// exploratory).
//
// Config changes split by kind. Pure drift -- plot height, dpr, channel
// add/remove -- reuses old tiles (ghosts/shifts) while the rolling sweep
// re-bakes them. Tares do NOT reuse: a tare shifts each channel by its own
// display offset, and one tile composites every channel, so no single blit
// correction can hold every trace -- tares ride the destructive key with
// unit/calibration (never blitted once stale, blank per above).
// The sweep re-bakes config-stale segments rightmost-first (freshest data
// converges first, history backfills) at the usual [kSegmentBakeBudget] per
// frame. On any config bump, segments outside the view are disposed so stale
// content cannot resurrect on a later pan.
//
// Quality invariant: a texture is only ever produced by a vector render --
// never by resampling another texture -- so every on-screen pixel is at most
// ONE bilinear resample away from a vector render, scaled by at most
// ~kMaxSegmentDrift before a refresh re-sharpens it.
//
// Live-edge invariant: baked tiles always contain complete data. Segments
// never end past a bake horizon ([SegmentedGraphCache.maintain]'s
// bakeableSamples) that excludes the renderer's incomplete tail at the data
// edge (the envelope layer's join block); that trailing span is vector-drawn
// every frame instead. No tile can therefore go stale at its right seam as
// samples arrive.
// ---------------------------------------------------------------------------

/// Target on-screen width (logical px) of one baked segment texture.
const double kSegmentTargetPx = 200;

/// Max relative scale drift (horizontal or vertical) a visible segment may
/// accumulate before its rolling re-render. Bounds the resampling quality
/// loss between bake and refresh.
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

/// Segment (re)bakes allowed per frame. Each costs time in UI-thread
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
/// current y-mapping. Called both to bake segment textures and to draw
/// uncovered gaps directly to the frame canvas. Returns the logical px the
/// content occupies (x in [0, contentW) after the hPad translate); the
/// blit's x-scale reference. At most the allocated texW.
typedef SegmentRenderer =
    double Function(Canvas canvas, int start, int end, int texW);

/// Everything one (re)bake needs, computed once per
/// [SegmentedGraphCache.paint] call.
typedef _BakeEnv = ({
  double pps,
  double gh,
  double dpr,
  int viewStart,
  int viewEnd,
  double yMin,
  double yMax,
  int bakeable,
  int targetSpan,
  double hPad,
  double vPad,
  SegmentRenderer render,
});

/// One baked segment: an immutable vector render of samples [start, end)
/// plus the mapping and config it was baked under. Never mutated and never
/// re-blitted into another texture (so resampling loss cannot compound);
/// replaced by a fresh vector render when stale.
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

  GraphSegment({
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

class SegmentedGraphCache {
  /// Baked segments ordered by [GraphSegment.start]. Overlaps are allowed
  /// (a refresh may extend over a neighbor; clipped at blit time in the left
  /// segment's favor, which is always the fresher one); gaps are drawn as
  /// vectors or left blank until a bake covers them.
  final List<GraphSegment> _segments = [];

  /// Current bake config. Segments carry their own stamps: a destructiveKey
  /// mismatch suppresses the blit (its pixels draw nothing until re-baked);
  /// a remapKey/gh/dpr mismatch keeps blitting (best-effort ghost/shift) --
  /// except past an extreme vertical stretch, where the blit smears and
  /// [_isBlittable] suppresses it -- and marks the segment for the rolling
  /// config sweep. gh and dpr are
  /// deliberately NOT destructive: both are pure drift the blit affine
  /// corrects for. [_generation] identifies the data stream itself; a change
  /// clears everything (different data at the same absolute indices) -- the
  /// only mass clear, and cheap since a fresh stream has little data.
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

  /// Advance the cache toward the window [viewStart, viewStart + viewSpan)
  /// without drawing: apply generation/config changes, evict segments far
  /// outside the view, and spend up to [kSegmentBakeBudget] segment
  /// (re)bakes.
  ///
  /// Config identity is split in three (see the file header for the model):
  /// [generation] clears the cache on change; [destructiveKey] (unit,
  /// calibration, tares) suppresses blitting of mismatched segments;
  /// [remapKey] (channels) keeps them blitting. Both kinds of mismatch are
  /// re-baked by the rolling rightmost-first sweep at the bake budget, so a
  /// config change never costs more than one bake per call.
  ///
  /// [bakeableSamples] caps segment coverage: no bake ever ends past it.
  /// Renderers pass the data edge minus the span their tail needs to be
  /// final (the envelope layer's join block past a segment end: up to two
  /// block sizes, see joinBlockEnd in graph_components.dart), so every baked
  /// tile reduces only complete blocks -- see the live-edge invariant in the
  /// file header. The trailing span past the horizon is never baked and
  /// vector-draws every frame via [draw].
  ///
  /// Returns true when a bake happened — rolling work may remain, so the
  /// owner should schedule another pass.
  bool maintain({
    required int generation,
    required List<Object?> destructiveKey,
    required List<Object?> remapKey,
    required double gw,
    required double gh,
    required double dpr,
    required double viewStart,
    required double viewSpan,
    required double yMin,
    required double yMax,
    required int bakeableSamples,
    required double hPad,
    required double vPad,
    required SegmentRenderer render,
  }) {
    if (generation != _generation) {
      clear();
      _generation = generation;
      _gh = gh;
      _dpr = dpr;
      _destructiveKey = List.of(destructiveKey);
      _remapKey = List.of(remapKey);
    }

    final double pps = gw / viewSpan; // logical px per sample
    final double viewEnd = viewStart + viewSpan;
    final int targetSpan = math.max(1, (kSegmentTargetPx / pps).round());
    // Coverage bookkeeping is integer: bakes and gap ranges are
    // sample-aligned (block anchoring). The fractional scroll offset only
    // shifts blit placement, in [draw].
    final int covStart = viewStart.floor();
    final int covEnd = viewEnd.ceil();

    // Config bump: keep stale segments (they degrade per their key kind)
    // but dispose any outside the view, so stale content -- e.g. a removed
    // channel's ghost -- cannot resurrect on a later pan before the sweep
    // reaches it. Disposed ranges simply vector-draw if panned back to.
    if (!listEquals(destructiveKey, _destructiveKey) ||
        !listEquals(remapKey, _remapKey) ||
        (gh - _gh).abs() > 0.1 ||
        dpr != _dpr) {
      _segments.removeWhere((s) {
        if (s.end > covStart && s.start < covEnd) return false;
        s.dispose();
        return true;
      });
      _gh = gh;
      _dpr = dpr;
      _destructiveKey = List.of(destructiveKey);
      _remapKey = List.of(remapKey);
    }

    final env = (
      pps: pps,
      gh: gh,
      dpr: dpr,
      viewStart: covStart,
      viewEnd: covEnd,
      yMin: yMin,
      yMax: yMax,
      bakeable: bakeableSamples,
      targetSpan: targetSpan,
      hPad: hPad,
      vPad: vPad,
      render: render,
    );

    // Evict segments far outside the view.
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

    return baked;
  }

  /// Draw the window [viewStart, viewStart + viewSpan) mapped to x in
  /// [0, gw): blit cached segments under their corrective affine transforms
  /// and vector-draw the uncovered gaps.
  void draw(
    Canvas canvas, {
    required double gw,
    required double gh,
    required double viewStart,
    required double viewSpan,
    required double yMin,
    required double yMax,
    required int totalSamples,
    required double vPad,
    required SegmentRenderer render,
  }) {
    final double pps = gw / viewSpan;
    final double viewEnd = viewStart + viewSpan;
    _blitSegments(canvas, pps, gw, gh, viewStart, yMin, yMax);
    _drawGaps(
      canvas,
      pps,
      gw,
      gh,
      viewStart,
      viewEnd,
      totalSamples,
      vPad,
      render,
    );
  }

  /// One [maintain] + [draw] pass for the window [viewStart, viewStart +
  /// viewSpan) mapped to x in [0, gw). [totalSamples] is the data edge the
  /// draw covers (see [draw]); [bakeableSamples] caps segment coverage (see
  /// [maintain]).
  ///
  /// Returns true when a bake happened this frame; the owner should then
  /// schedule another frame so rolling bakes continue (one extra frame may
  /// be scheduled after the final bake — static sources never fire repaint
  /// on their own).
  bool paint(
    Canvas canvas, {
    required int generation,
    required List<Object?> destructiveKey,
    required List<Object?> remapKey,
    required double gw,
    required double gh,
    required double dpr,
    required double viewStart,
    required double viewSpan,
    required double yMin,
    required double yMax,
    required int totalSamples,
    required int bakeableSamples,
    required double hPad,
    required double vPad,
    required SegmentRenderer render,
  }) {
    final baked = maintain(
      generation: generation,
      destructiveKey: destructiveKey,
      remapKey: remapKey,
      gw: gw,
      gh: gh,
      dpr: dpr,
      viewStart: viewStart,
      viewSpan: viewSpan,
      yMin: yMin,
      yMax: yMax,
      bakeableSamples: bakeableSamples,
      hPad: hPad,
      vPad: vPad,
      render: render,
    );
    draw(
      canvas,
      gw: gw,
      gh: gh,
      viewStart: viewStart,
      viewSpan: viewSpan,
      yMin: yMin,
      yMax: yMax,
      totalSamples: totalSamples,
      vPad: vPad,
      render: render,
    );
    return baked;
  }

  /// Uncovered sub-ranges of [viewStart, min(viewEnd, totalSamples)).
  /// Coverage is purely geometric: a segment counts as covered even when it
  /// may not blit ([_isBlittable]), because unblittable content draws
  /// NOTHING (see the raster budget in the file header) instead of
  /// vector-redrawing its range.
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
  ///   2. the rightmost visible segment baked under outdated config (the
  ///      destructive/remap sweep: freshest data converges first, history
  ///      backfills);
  ///   3. the visible segment furthest past its drift/size thresholds
  ///      (rolling refresh, merging undersized neighbors and splitting
  ///      oversized ranges).
  /// Returns whether a bake happened.
  bool _bakeOne(_BakeEnv env) =>
      _bakeWidestGap(env) ||
      _sweepConfigStaleSegment(env) ||
      _refreshStalestSegment(env);

  /// Priority 1: bake the widest uncovered gap past the threshold (left
  /// aligned, so a gap touching the data edge leaves the sub-threshold
  /// sliver AT the edge -- the live-edge sliver the absorb below grows in
  /// place). Right-to-left convergence after config bumps is the sweep's
  /// job (priority 2), not this pass's. Left neighbors are absorbed while
  /// the merged bake stays within one target width, so the live-edge
  /// segment grows in place (one bake per sliver) instead of accumulating
  /// sliver-wide strips.
  bool _bakeWidestGap(_BakeEnv env) {
    (int, int)? bakeGap;
    double widestPx = kSegmentGapBakePx;
    for (final g in _gaps(env.viewStart, env.viewEnd, env.bakeable)) {
      final double w = (g.$2 - g.$1) * env.pps;
      if (w > widestPx) {
        widestPx = w;
        bakeGap = g;
      }
    }
    if (bakeGap == null) return false;

    int start = bakeGap.$1;
    final int end = math.min(bakeGap.$2, start + env.targetSpan);
    if (end <= start) return false;
    assert(end <= env.bakeable); // _gaps caps domainEnd at the bake horizon

    // Insertion point: first segment starting inside/after the bake range.
    int at = 0;
    while (at < _segments.length && _segments[at].start < start) {
      at++;
    }
    while (at > 0 &&
        (end - _segments[at - 1].start) * env.pps <= kSegmentTargetPx) {
      at--;
      start = _segments[at].start;
      _segments[at].dispose();
      _segments.removeAt(at);
    }

    _segments.insert(at, _bake(start, end, env));
    return true;
  }

  /// Priority 2: refresh the RIGHTMOST visible segment whose bake config no
  /// longer matches -- the smeared rebake after a config bump. Destructive
  /// mismatches (unit, calibration, tares) are never blitted meanwhile
  /// (their pixels draw nothing -- blank-then-refill); remap mismatches
  /// (channels, gh, dpr) keep blitting as best-effort ghosts/shifts.
  /// Right-to-left so the live edge converges first and history backfills.
  ///
  /// A stale segment starting at or past the bake horizon is dropped, not
  /// re-baked: its range falls to the per-frame vector draw (see
  /// [_refreshRange] for when the horizon can recede under an old segment).
  bool _sweepConfigStaleSegment(_BakeEnv env) {
    for (int i = _segments.length - 1; i >= 0; i--) {
      final s = _segments[i];
      if (s.end <= env.viewStart || s.start >= env.viewEnd) continue;
      if (!_isConfigStale(s, env)) continue;
      final range = _refreshRange(i, env);
      if (range.end <= range.start) {
        _segments.removeAt(i).dispose();
        continue;
      }
      _splice(i, range.removeTo, _bake(range.start, range.end, env));
      return true;
    }
    return false;
  }

  /// Whether [s] may blit under the current Y-mapping: the destructive key
  /// must match, and the corrective vertical stretch must keep the baked
  /// line ([kBakedLinePx] at bake) within [kMaxBlitLineFraction] of the plot
  /// height. One-sided: shrinking only sharpens, but a large stretch -- e.g.
  /// the Y-range collapsing onto a quiet channel -- smears the tile's line
  /// across the screen. Suppressed segments are kept (a range snap-back
  /// makes them blittable again); the sweep/refresh passes re-bake them and
  /// their pixels draw nothing meanwhile.
  bool _isBlittable(GraphSegment s, double yMin, double yMax, double gh) {
    if (!listEquals(s.destructiveKey, _destructiveKey)) return false;
    final double ys = (s.yMax - s.yMin) / (yMax - yMin) * (gh / s.gh);
    return ys * kBakedLinePx <= gh * kMaxBlitLineFraction;
  }

  /// Whether [s] was baked under outdated config (any kind).
  bool _isConfigStale(GraphSegment s, _BakeEnv env) =>
      !listEquals(s.destructiveKey, _destructiveKey) ||
      !listEquals(s.remapKey, _remapKey) ||
      (s.gh - env.gh).abs() > 0.1 ||
      s.dpr != env.dpr;

  /// Priority 3: refresh the visible segment furthest past its drift/size
  /// thresholds, merging undersized neighbors and splitting oversized ranges
  /// (see [_refreshRange]). A stale segment starting at or past the bake
  /// horizon is dropped instead (see [_sweepConfigStaleSegment]).
  bool _refreshStalestSegment(_BakeEnv env) {
    // Score each visible segment; > 1.0 means past a threshold. Under
    // uniform squeeze all segments drift together, so picking the worst
    // (first on ties) degenerates into a round-robin.
    int worst = -1;
    double worstScore = 1.0;
    for (int i = 0; i < _segments.length; i++) {
      final s = _segments[i];
      if (s.end <= env.viewStart || s.start >= env.viewEnd) continue;
      final double w = (s.end - s.start) * env.pps;
      final double xScale = w / s.contentW;
      final double yScale = (s.yMax - s.yMin) / (env.yMax - env.yMin);
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

    final range = _refreshRange(worst, env);
    if (range.end <= range.start) {
      _segments.removeAt(worst).dispose();
      return true;
    }

    final seg = _bake(range.start, range.end, env);
    _splice(worst, range.removeTo, seg);
    return true;
  }

  /// The (re)bake range for refreshing segment [i], plus the inclusive last
  /// segment index it replaces: merge right neighbors while the result stays
  /// under 1.5 targets (never merging across a gap); when still undersized,
  /// extend into the oversized right neighbor (the overlap is clipped at
  /// blit time in this segment's favor, and fully-covered neighbors are
  /// replaced outright); when oversized, clamp to one target width (the
  /// remainder becomes a gap that refills over the following frames).
  ///
  /// The end is clamped to the bake horizon, which can recede under an old
  /// segment ([SegmentedGraphCache.maintain] explains the horizon); a
  /// segment starting at or past it yields an empty range, and the caller
  /// drops the segment instead of re-baking it.
  ({int start, int end, int removeTo}) _refreshRange(int i, _BakeEnv env) {
    final s = _segments[i];
    final int newStart = s.start;
    int newEnd = s.end;
    int removeTo = i;
    // Merge right neighbors while the result stays under 1.5 targets.
    while (removeTo + 1 < _segments.length) {
      final n = _segments[removeTo + 1];
      if (n.start > newEnd) break; // never merge across a gap
      if ((n.end - newStart) * env.pps > 1.5 * kSegmentTargetPx) break;
      newEnd = math.max(newEnd, n.end);
      removeTo++;
    }
    if ((newEnd - newStart) * env.pps < kSegmentTargetPx / 2) {
      // Still undersized (right neighbor too big to swallow whole): extend
      // into it.
      newEnd = math.min(env.bakeable, newStart + env.targetSpan);
      while (removeTo + 1 < _segments.length &&
          _segments[removeTo + 1].end <= newEnd) {
        removeTo++;
      }
    }
    if ((newEnd - newStart) * env.pps > 2 * kSegmentTargetPx) {
      // Oversized: bake only the leading target-width range.
      newEnd = newStart + env.targetSpan;
    }
    newEnd = math.min(newEnd, env.bakeable);
    return (start: newStart, end: newEnd, removeTo: removeTo);
  }

  /// Replace segments [from..to] (inclusive) with [seg], disposing the
  /// replaced ones.
  void _splice(int from, int to, GraphSegment seg) {
    for (int k = from; k <= to; k++) {
      _segments[k].dispose();
    }
    _segments.replaceRange(from, to + 1, [seg]);
  }

  /// Vector-render samples [start, end) into a fresh texture sized to the
  /// range's current on-screen width, so its blit starts at scale ~1.
  /// Stamped with the cache's current config (see [GraphSegment]).
  GraphSegment _bake(int start, int end, _BakeEnv env) {
    final int texW = math.max(1, ((end - start) * env.pps).ceil());
    double contentW = texW.toDouble();
    final img = _bakeImage(
      ((texW + 2 * env.hPad) * env.dpr).ceil(),
      ((env.gh + 2 * env.vPad) * env.dpr).ceil(),
      env.dpr,
      (c) {
        c.translate(env.hPad, env.vPad);
        contentW = env.render(c, start, end, texW);
      },
    );
    return GraphSegment(
      image: img,
      start: start,
      end: end,
      contentW: math.max(contentW, 0.001),
      yMin: env.yMin,
      yMax: env.yMax,
      gh: env.gh,
      dpr: env.dpr,
      destructiveKey: _destructiveKey,
      remapKey: _remapKey,
      hPad: env.hPad,
      vPad: env.vPad,
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
  /// one tile composites every channel, so no single affine can hold
  /// per-channel shifts -- tares ride the destructive key instead.
  ///
  /// Unblittable segments ([_isBlittable]) are never blitted: a destructive
  /// key mismatch is wrong in kind or place (a counts-shaped trace on a kg
  /// axis, a pre-tare trace) and an extreme vertical stretch reads as a
  /// screen-filling smear. Their pixels draw nothing until the sweep
  /// re-bakes them -- blank, never vector-redrawn (see the raster budget in
  /// the file header). Remap-stale segments (channels, gh, dpr) DO blit
  /// -- outdated/shifted but approximately right -- until swept.
  void _blitSegments(
    Canvas canvas,
    double pps,
    double gw,
    double gh,
    double viewStart,
    double yMin,
    double yMax,
  ) {
    final double range = yMax - yMin;
    final paint = Paint()..filterQuality = kSegmentFilterQuality;
    double coveredX = 0;
    for (final s in _segments) {
      if (!_isBlittable(s, yMin, yMax, gh)) continue;
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
      // Total y scale: value-range drift (first factor) rescaled into today's
      // pixel height (second factor). Where the tile's top content row
      // (value s.yMax) lands today:
      final double ys = (s.yMax - s.yMin) / range * (gh / s.gh);
      final double yTop = gh * (1 - (s.yMax - yMin) / range);

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

  /// Vector-render the uncovered visible ranges (live-edge sliver, freshly
  /// exposed pan/zoom territory, bake backlog). Ranges covered by an
  /// unblittable segment ([_isBlittable]) draw NOTHING: their pixels stay
  /// blank until the sweep re-bakes them -- the deliberate
  /// blank-then-refill that bounds per-frame raster work on config bumps
  /// (see the file header).
  void _drawGaps(
    Canvas canvas,
    double pps,
    double gw,
    double gh,
    double viewStart,
    double viewEnd,
    int totalSamples,
    double vPad,
    SegmentRenderer render,
  ) {
    for (final (gs, ge) in _gaps(
      viewStart.floor(),
      viewEnd.ceil(),
      totalSamples,
    )) {
      final double w = (ge - gs) * pps;
      if (w <= 0) continue;
      final double x = (gs - viewStart) * pps;
      canvas.save();
      // The floored coverage start can put a gap's left edge up to one
      // sample-pixel left of the plot area; the translate keeps the content
      // mapping exact, so the clip is what gets clamped.
      canvas.clipRect(
        Rect.fromLTRB(math.max(x, 0.0), -vPad, math.min(x + w, gw), gh + vPad),
      );
      canvas.translate(x, 0);
      render(canvas, gs, ge, math.max(1, w.ceil()));
      canvas.restore();
    }
  }
}

// ---------------------------------------------------------------------------
// Bake pump (shared repaint driver for the rolling segment bake)
// ---------------------------------------------------------------------------

/// Extra repaint driver for the rolling segment bake: baking is rationed to
/// [kSegmentBakeBudget] segments per frame, so when work remains a painter
/// calls [schedule], which ticks [Listenable] listeners after the frame.
/// Needed for static sources (loaded sessions) whose GraphDataSource repaint
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
