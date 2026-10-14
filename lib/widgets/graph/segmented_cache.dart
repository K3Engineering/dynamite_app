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

class SegmentedGraphCache {
  /// Baked segments ordered by [GraphSegment.start]. Overlaps are allowed
  /// (a refresh may extend over a neighbor; clipped at blit time in the left
  /// segment's favor, which is always the fresher one); gaps are drawn as
  /// vectors or left blank until a bake covers them.
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
    final baked = _maintain(c);
    _draw(canvas, c);
    return baked;
  }

  /// The maintenance half of [paint]: everything except the raster.
  bool _maintain(SegmentViewConfig c) {
    if (c.generation != _generation) {
      clear();
      _generation = c.generation;
      _gh = c.gh;
      _dpr = c.dpr;
      _destructiveKey = List.of(c.destructiveKey);
      _remapKey = List.of(c.remapKey);
    }

    final double pps = c.gw / c.viewSpan; // logical px per sample
    final double viewEnd = c.viewStart + c.viewSpan;
    final int targetSpan = math.max(1, (kSegmentTargetPx / pps).round());
    // Coverage bookkeeping is integer: bakes and gap ranges are
    // sample-aligned (block anchoring). The fractional scroll offset only
    // shifts blit placement, in [_draw].
    final int covStart = c.viewStart.floor();
    final int covEnd = viewEnd.ceil();

    // Config bump: dispose stale segments outside the view, so they cannot
    // resurrect on a later pan before the sweep reaches them. Disposed
    // ranges vector-draw if panned back to.
    if (!listEquals(c.destructiveKey, _destructiveKey) ||
        !listEquals(c.remapKey, _remapKey) ||
        (c.gh - _gh).abs() > 0.1 ||
        c.dpr != _dpr) {
      _segments.removeWhere((s) {
        if (s.end > covStart && s.start < covEnd) return false;
        s.dispose();
        return true;
      });
      _gh = c.gh;
      _dpr = c.dpr;
      _destructiveKey = List.of(c.destructiveKey);
      _remapKey = List.of(c.remapKey);
    }

    final env = (
      pps: pps,
      gh: c.gh,
      dpr: c.dpr,
      viewStart: covStart,
      viewEnd: covEnd,
      yMin: c.yMin,
      yMax: c.yMax,
      bakeable: c.bakeableSamples,
      targetSpan: targetSpan,
      hPad: c.hPad,
      vPad: c.vPad,
      render: c.render,
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

    return baked;
  }

  /// The raster half of [paint]: blit the cached segments for the window
  /// mapped to x in [0, gw), and vector-draw the uncovered gaps.
  void _draw(Canvas canvas, SegmentViewConfig c) {
    final double pps = c.gw / c.viewSpan;
    final double viewEnd = c.viewStart + c.viewSpan;
    _blitSegments(canvas, pps, c.gw, c.gh, c.viewStart, c.yMin, c.yMax);
    _drawGaps(
      canvas,
      pps,
      c.gw,
      c.gh,
      c.viewStart,
      viewEnd,
      c.totalSamples,
      c.vPad,
      c.render,
    );
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
    for (final g in _gaps(env.viewStart, env.viewEnd, env.bakeable)) {
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
    if (end <= start) return false;
    assert(
      end <= env.bakeable,
      'bake range end $end exceeds bake horizon ${env.bakeable}',
    ); // _gaps caps domainEnd at the bake horizon

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

  /// Priority 2: re-bake the rightmost visible stale segment (any kind --
  /// see [_isStale]) to the fixed range [_refreshEnd] computes.
  bool _refreshStaleSegment(_BakeEnv env) {
    for (int i = _segments.length - 1; i >= 0; i--) {
      final s = _segments[i];
      if (s.end <= env.viewStart || s.start >= env.viewEnd) continue;
      if (!_isStale(s, env)) continue;
      final int end = _refreshEnd(s, env);
      if (end <= s.start) {
        _segments.removeAt(i).dispose();
        continue;
      }
      // Only segments fully inside the range are replaced; a partially
      // overlapped right neighbor stays, and the left-wins blit clip (see
      // [_blitSegments]) renders the overlap in this fresher segment's
      // favor.
      int removeTo = i;
      while (removeTo + 1 < _segments.length &&
          _segments[removeTo + 1].end <= end) {
        removeTo++;
      }
      _splice(i, removeTo, _bake(s.start, end, env));
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

  /// Whether visible [s] needs a re-bake:
  ///   * config-stale -- baked under outdated keys/gh/dpr;
  ///   * drift-stale -- x- or y-scale drift past [kMaxSegmentDrift];
  ///   * size-stale -- [_refreshEnd] would move [s]'s far edge with the
  ///     refresh making progress: past two targets on screen the refresh
  ///     clamps to one target (the remainder becomes a gap that refills);
  ///     meaningfully narrow with room to its right the refresh extends to
  ///     one target span (a neighbor to consolidate, or live-edge room; a
  ///     segment ending at the bake horizon has none and stays).
  ///
  /// Size-staleness is defined by whether the refresh makes progress.
  /// Gap bakes birth segments up to a target plus
  /// [kSegmentGapBakePx] (the swallow), and
  /// `targetSpan = round(kSegmentTargetPx / pps)` lands a nominal
  /// full-target segment up to `pps/2` px off 200 either way -- well under
  /// either threshold, so births are never size-stale. Config/drift
  /// staleness refreshes in place: the range reproduces but the content
  /// updates. Every re-bake therefore either changes the range (size) or
  /// updates the content (config/drift), and the scan goes quiescent.
  bool _isStale(GraphSegment s, _BakeEnv env) {
    if (_isConfigStale(s, env)) return true;
    final double w = (s.end - s.start) * env.pps;
    final double xScale = w / s.contentW;
    final double yScale = (s.yMax - s.yMin) / (env.yMax - env.yMin);
    if (math.max((1 - xScale).abs(), (1 - yScale).abs()) > kMaxSegmentDrift) {
      return true;
    }
    // Past two targets: split. The second clause is the progress guard:
    // at pps over ~200 px/sample targetSpan hits its 1-sample floor and
    // the clamp cannot shrink the segment, so it must not fire.
    if (w > 2 * kSegmentTargetPx && s.start + env.targetSpan < s.end) {
      return true;
    }
    return w < kSegmentTargetPx / 2 &&
        math.min(s.start + env.targetSpan, env.bakeable) > s.end;
  }

  /// The re-bake end for a stale segment [s]: coverage-preserving -- the
  /// segment keeps its own range, so a refresh is one bake with no hole to
  /// refill. Extended to one target span when [s] is narrow ([_isStale]
  /// gates the extension on the room existing), clamped to one target span
  /// past two targets on screen (the remainder becomes a gap that refills
  /// over the following frames). Capped at the bake horizon, which can
  /// recede under an old segment (block-size jumps); a segment starting at
  /// or past the horizon gets an empty range, and the caller drops it.
  int _refreshEnd(GraphSegment s, _BakeEnv env) {
    int end = math.max(s.end, s.start + env.targetSpan);
    if ((end - s.start) * env.pps > 2 * kSegmentTargetPx) {
      end = s.start + env.targetSpan;
    }
    return math.min(end, env.bakeable);
  }

  void _splice(int from, int to, GraphSegment seg) {
    for (int k = from; k <= to; k++) {
      _segments[k].dispose();
    }
    _segments.replaceRange(from, to + 1, [seg]);
  }

  /// Vector-render samples [start, end) into a fresh texture sized to the
  /// range's current on-screen width, so its blit starts at scale ~1.
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
  /// one segment composites every channel, so no single affine can hold
  /// per-channel shifts -- tares ride the destructive key instead.
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
      // pixel height (second factor). Where the segment's top content row
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

  /// Vector-render the uncovered visible ranges (see the file header).
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
