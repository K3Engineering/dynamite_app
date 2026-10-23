import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meta/meta.dart';

import 'segmented_cache_functional.dart';

// ---------------------------------------------------------------------------
// Segmented graph cache: raster shell
//
// One caching mechanism shared by every plot surface (minimap, force graph,
// derivative graph) in both viewing modes:
//   * slide   -- a fixed-span window slides over the data: blits are pure
//                translations;
//   * squeeze -- the window spans the whole growing history: blits get a
//                corrective affine transform (both axis mappings are affine).
//
// Vector-redrawing the whole plot every frame caused low framerates. Web has no
// engine raster cache: a ui.Picture re-executes on Skia every frame. Immutable
// sample ranges are baked once into GPU ui.Images and blitted; rebakes are
// smeared across frames at one bake per frame, because a burst of work in one
// frame shows up as a stutter.
//
// The decisions live in segmented_cache_functional.dart; this file owns
// ui.Image creation and disposal, canvas calls and bake scheduling (BakePump).
// One frame (see that file's header for the transitions):
//   prepareFrame -> planBakes -> [this file rasterizes] -> applyBake
//   -> rasterPlan -> [this file draws]
//
// Config changes split by kind. Plot height, dpr, channel add/remove are pure
// drift: old segments keep blitting (ghosts/shifts) while the sweep re-bakes
// them rightmost-first. Tares ride the destructive key with unit/calibration
// instead: one segment composites every channel, so no single blit correction
// can hold per-channel shifts.
//
// Live-edge invariant: no BAKE ends past the bake horizon
// (CacheConfig.bakeableSamples) that excludes the filling block and horizon zone
// at the data edge; both vector-draw every frame instead. A segment already
// baked may keep an end past a horizon that later receded under it -- its pixels
// exist and stay blittable -- so the invariant constrains bakes, not the
// segment list (see [invariantViolations]).
//
// Fold-window invariant: a bake never covers samples outside the window the
// frame's Y-range was folded from (the cache's covStart..covEnd, computed as the
// same floor/ceil of the same window the painters fold their extremes over). A
// bake renders under the frame's yMin..yMax; samples the fold doesn't cover land
// past valueToY < -vPad and are raster-clipped at the texture edge, and that cut
// is frozen into the texture -- no later blit correction or sweep restores texels
// that were never recorded. Segments may still STRADDLE the window edges from
// window motion; but a re-bake of one clamps its coverage into the window,
// dropping the out-of-fold fringe to a gap that vector-draws when panned back to
// and bakes under a fold that includes it. Both invariants are asserted in
// planBakes, which every bake decision passes through.
// ---------------------------------------------------------------------------

/// Base padding (logical px) baked around a segment texture so AA stroke bleed
/// survives the image crop. Renderers that overshoot the segment bounds (the
/// graphs' one-block polyline join) pass a larger horizontal pad.
const double kSegmentImagePad = 4;

/// [FilterQuality.none] showed gaps and seams in testing; bilinear does not.
const FilterQuality kSegmentFilterQuality = FilterQuality.low;

/// Renders samples [start, end) mapped to x in [0, ~texW) at the plot's current
/// y-mapping. Called both to bake segment textures and to draw uncovered gaps
/// directly to the frame canvas. Returns the logical px the content occupies (x
/// in [0, contentW) after the hPad translate); the blit's x-scale reference. At
/// most the allocated texW.
typedef SegmentRenderer =
    double Function(Canvas canvas, int start, int end, int texW);

/// One frame of inputs for [SegmentedGraphCache.paint]: the core's [CacheConfig]
/// plus the one impure input, the vector renderer.
///
/// The config is EMBEDDED rather than flattened so [CacheConfig] stays the single
/// field list: a flattened copy here would compile after a field was added on one
/// side only, silently dropping it.
typedef SegmentViewConfig = ({CacheConfig config, SegmentRenderer render});

/// One blit as handed to the canvas, for tests: the same rects
/// [Canvas.drawImageRect] received, so a wrong operand order in [_drawBlits] is
/// visible.
@visibleForTesting
typedef DrawnBlit = ({SegmentMeta seg, Rect src, Rect dst, Rect clip});

/// One gap render as handed to the canvas, for tests.
@visibleForTesting
typedef DrawnGap = ({int start, int end, double x, int texW, Rect clip});

/// Record [draw] and rasterize it into a [widthPx] x [heightPx] physical-pixel
/// [ui.Image]. The canvas is pre-scaled by [dpr] so [draw] works in logical px.
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

/// The impure shell over the functional core: owns the textures (textureId ->
/// ui.Image), executes the bake planBakes decides on, and rasterizes rasterPlan.
class SegmentedGraphCache {
  /// Null until the first [paint]: a fresh cache has no stamps to compare
  /// against, so "nothing yet" is the absence of a state rather than a stamped
  /// sentinel.
  CacheState? _state;

  /// Textures keyed by [SegmentMeta.textureId]. Each frame reconciles this map
  /// against the frame's segment list (see [_reconcileTextures]), so the map and
  /// the state cannot drift apart and no drop list has to be threaded out of the
  /// core.
  final Map<int, ui.Image> _images = {};

  /// Serial source for [SegmentMeta.textureId]; never reused, so a stale id can
  /// never alias a live texture.
  int _nextTextureId = 0;

  void clear() {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    _state = null;
  }

  void dispose() => clear();

  /// What the last [paint] handed to the canvas: the resolved rects, recorded at
  /// the draw call rather than at planning time, so the shell's operand order and
  /// clamping are covered too. Null until the first frame. Both lists are reused
  /// between frames (cleared, never reallocated), so recording costs one record
  /// per drawn item and no list churn.
  @visibleForTesting
  ({List<DrawnBlit> blits, List<DrawnGap> gaps})? get debugLastRaster =>
      _firstFrameDrawn ? null : (blits: _drawnBlits, gaps: _drawnGaps);

  final List<DrawnBlit> _drawnBlits = [];
  final List<DrawnGap> _drawnGaps = [];
  bool _firstFrameDrawn = true;

  /// Recording exists for tests and is compiled out of release builds, so the
  /// per-draw record append costs nothing in the app.
  static const bool _kRecordRaster = !bool.fromEnvironment('dart.vm.product');

  /// The textures this cache holds, by id, for tests that assert disposal.
  @visibleForTesting
  Map<int, ui.Image> get debugTextures => _images;

  /// Bring the cache up to date for the frame [c] and blit it: apply
  /// generation/config changes, evict segments far outside the view, spend at
  /// most one segment (re)bake, then blit the cached segments for the window and
  /// vector-draw the uncovered gaps up to totalSamples.
  ///
  /// Config identity is split in three (see the file header for the model):
  /// generation clears the cache on change; destructiveKey (unit, calibration,
  /// tares) suppresses blitting of mismatched segments; remapKey (channels)
  /// keeps them blitting. Both kinds of mismatch are re-baked by the rolling
  /// rightmost-first sweep, so a config change never costs more than one bake per
  /// call.
  ///
  /// bakeableSamples caps segment coverage: no bake ever ends past it (see the
  /// live-edge invariant in the file header).
  ///
  /// Returns true when a bake happened this frame; the owner should then
  /// schedule another frame so rolling bakes continue (static sources never fire
  /// repaint on their own).
  @useResult
  bool paint(Canvas canvas, SegmentViewConfig c) {
    final env = cacheEnvFor(c.config);
    final state = prepareFrame(_state, env);
    final plan = planBakes(state, env);

    // Rasterize the bake the core decided on, filing the texture under the id it
    // reports. Null when the frame is quiet: no texture, no serial advance.
    final bake = plan == null ? null : _executeBake(plan, env, c);
    final previous = _state?.segments;
    final committed = _state = applyBake(state, env, bake);
    // prepareFrame hands back the same list on a quiet frame, so a changed list
    // is the only way the texture map can have drifted. The assert below checks
    // that shortcut against the map itself.
    if (!identical(previous, committed.segments)) {
      _reconcileTextures(committed);
    }
    assert(invariantViolations(committed).isEmpty);
    assert(_texturesMatchState(committed));

    final raster = rasterPlan(committed, env);
    if (_kRecordRaster) {
      _drawnBlits.clear();
      _drawnGaps.clear();
      _firstFrameDrawn = false;
    }
    _drawBlits(canvas, raster.blits);
    _drawGaps(canvas, raster.gaps, c);
    return plan != null;
  }

  /// Dispose every texture [state]'s segment list no longer names. A texture is
  /// live iff a segment carries its id, so the state is the single source of
  /// truth and a texture dropped anywhere in the core (eviction, generation
  /// reset, splice) frees here, on that frame. [_executeBake] has already filed
  /// the frame's own bake, whose id the committed segment carries.
  void _reconcileTextures(CacheState state) {
    final live = {for (final s in state.segments) s.textureId};
    for (final id in _images.keys.toList()) {
      if (live.contains(id)) continue;
      _images.remove(id)!.dispose();
    }
  }

  /// Debug-only: every segment owns a live texture and no texture is orphaned.
  /// This checks the reconcile shortcut in [paint] against the map.
  bool _texturesMatchState(CacheState state) {
    final ids = {for (final s in state.segments) s.textureId};
    return ids.length == state.segments.length &&
        ids.every(_images.containsKey) &&
        _images.length == ids.length;
  }

  /// Rasterize one [plan]'s range with the frame's render closure, sized to the
  /// range's current on-screen width so its blit starts at scale ~1, and file
  /// the texture under a fresh id. The serial advances only here, so every id
  /// belongs to a bake that produced a texture. Returns the measurement paired
  /// with the plan that produced it, which is the value [applyBake] commits.
  FrameBake _executeBake(BakePlan plan, CacheEnv env, SegmentViewConfig c) {
    final int texW = math.max(1, ((plan.end - plan.start) * env.pps).ceil());
    double contentW = texW.toDouble();
    final cc = c.config;
    final img = _bakeImage(
      ((texW + 2 * cc.hPad) * cc.dpr).ceil(),
      ((cc.gh + 2 * cc.vPad) * cc.dpr).ceil(),
      cc.dpr,
      (canvas) {
        canvas.translate(cc.hPad, cc.vPad);
        contentW = c.render(canvas, plan.start, plan.end, texW);
      },
    );
    final bake = (plan: plan, contentW: contentW, textureId: _nextTextureId++);
    // Filed before the commit returns, so this frame's reconcile sees the new
    // segment's texture as live rather than orphaned.
    _images[bake.textureId] = img;
    return bake;
  }

  /// Blit resolved rects (see [BlitRect] for what the fields hold).
  void _drawBlits(Canvas canvas, List<BlitRect> blits) {
    final paint = Paint()..filterQuality = kSegmentFilterQuality;
    for (final b in blits) {
      final src = Rect.fromLTWH(0, 0, b.sw, b.sh);
      final dst = Rect.fromLTWH(b.dx, b.dy, b.dw, b.dh);
      final clip = Rect.fromLTRB(b.clipL, b.clipB, b.clipR, b.clipT);
      canvas.save();
      canvas.clipRect(clip);
      canvas.drawImageRect(_images[b.seg.textureId]!, src, dst, paint);
      canvas.restore();
      if (_kRecordRaster) {
        _drawnBlits.add((seg: b.seg, src: src, dst: dst, clip: clip));
      }
    }
  }

  /// Vector-render the uncovered visible ranges (see the file header).
  void _drawGaps(Canvas canvas, List<GapRect> gaps, SegmentViewConfig c) {
    for (final g in gaps) {
      final clip = Rect.fromLTRB(g.clipL, g.clipB, g.clipR, g.clipT);
      canvas.save();
      canvas.clipRect(clip);
      canvas.translate(g.x, 0);
      c.render(canvas, g.start, g.end, g.texW);
      canvas.restore();
      if (_kRecordRaster) {
        _drawnGaps.add((
          start: g.start,
          end: g.end,
          x: g.x,
          texW: g.texW,
          clip: clip,
        ));
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Bake pump (shared repaint driver for the rolling segment bake)
// ---------------------------------------------------------------------------

/// Repaint driver for the rolling segment bake: baking is rationed to one bake
/// per frame, so when work remains a painter calls [schedule], which ticks
/// listeners after the frame. Needed for static sources (loaded sessions) whose
/// GraphDataSource repaint never fires. Owned and disposed by the host widget's
/// State.
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
