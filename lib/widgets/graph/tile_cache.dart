import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meta/meta.dart';

import 'tile_cache_functional.dart';

// ---------------------------------------------------------------------------
// Tiled graph cache: raster shell
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
// The decisions live in tile_cache_functional.dart; this file owns
// ui.Image creation and disposal, canvas calls and bake scheduling (BakePump).
// One frame is one pure [stepCache] transition. This file fulfills the returned
// bake request, reconciles texture ownership, then draws the returned plan.
//
// Config changes split by kind. Plot height, dpr, channel add/remove are pure
// drift: old tiles keep blitting (ghosts/shifts) while the sweep re-bakes
// them rightmost-first. Tares ride the suppress key with unit/calibration
// instead: one tile composites every channel, so no single blit correction
// can hold per-channel shifts.
//
// Live-edge invariant: no BAKE ends past the bake horizon
// (CacheConfig.bakeHorizon) that excludes the filling block and horizon zone
// at the data edge; both vector-draw every frame instead. A tile already
// baked may keep an end past a horizon that later receded under it -- its pixels
// exist and stay blittable -- so the invariant constrains bakes, not the
// tile list (see [invariantViolations]).
//
// Fold-window invariant: a bake's nominal range stays inside covStart..covEnd.
// Painters fold Y over the larger absolute-block render span, including the
// left straddling block and right join blocks, so every rasterized extreme took
// part in the mapping. Re-bakes of window-straddling tiles clamp to covStart /
// covEnd, dropping the out-of-fold fringe to vector-drawn gaps. Coverage and
// horizon invariants are asserted in stepCache.
// ---------------------------------------------------------------------------

/// Base padding (logical px) baked around a tile texture so AA stroke bleed
/// survives the image crop. Renderers that overshoot the tile bounds (the
/// graphs' one-block polyline join) pass a larger horizontal pad.
const double kTileImagePad = 4;

/// [FilterQuality.none] showed gaps and seams in testing; bilinear does not.
const FilterQuality kTileFilterQuality = FilterQuality.low;

/// Renders samples [start, end) at the cache's current x/y mapping. Used both
/// for texture bakes and direct gap draws; content width is defined by pps.
typedef TileRenderer = void Function(Canvas canvas, int start, int end);

/// One frame of inputs for [TileGraphCache.paint]: the core's [CacheConfig]
/// plus the one impure input, the vector renderer.
///
/// The config is EMBEDDED rather than flattened so [CacheConfig] stays the single
/// field list: a flattened copy here would compile after a field was added on one
/// side only, silently dropping it.
typedef TileViewConfig = ({CacheConfig config, TileRenderer render});

/// One blit as handed to the canvas, for tests: the same rects
/// [Canvas.drawImageRect] received, so a wrong operand order in [_drawBlits] is
/// visible.
@visibleForTesting
typedef DrawnBlit = ({TileMeta tile, Rect src, Rect dst, Rect clip});

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

/// The impure shell over the functional core: owns textures, fulfills the
/// step's bake request and draws its raster plan.
class TileGraphCache {
  CacheState _state = const CacheState();

  /// Textures keyed by [TileMeta.textureId]. Each frame reconciles this map
  /// against the frame's tile list (see [_reconcileTextures]), so the map and
  /// the state cannot drift apart and no drop list has to be threaded out of the
  /// core.
  final Map<int, ui.Image> _images = {};

  void clear() {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    _state = const CacheState();
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
  /// generation/config changes, evict tiles far outside the view, spend at
  /// most one tile (re)bake, then blit the cached tiles for the window and
  /// vector-draw the uncovered gaps up to totalSamples.
  ///
  /// Config identity is split in three (see the file header for the model):
  /// generation clears the cache on change; suppressKey (unit, calibration,
  /// tares) suppresses blitting of mismatched tiles; ghostKey (channels)
  /// keeps them blitting. Both kinds of mismatch are re-baked by the rolling
  /// rightmost-first sweep, so a config change never costs more than one bake per
  /// call.
  ///
  /// bakeHorizon caps tile coverage: no bake ever ends past it (see the
  /// live-edge invariant in the file header).
  ///
  /// Returns true when a bake happened this frame; the owner should then
  /// schedule another frame so rolling bakes continue (static sources never fire
  /// repaint on their own).
  @useResult
  bool paint(Canvas canvas, TileViewConfig c) {
    final previous = _state.tiles;
    final step = stepCache(_state, c.config);
    final plan = step.frame.bake;
    final committed = _state = step.state;
    if (plan != null) {
      _executeBake(plan, committed.tiles[plan.from].textureId, c);
    }
    // A quiet pure step reuses the tile list. A changed list is the only way
    // the texture map can have drifted.
    if (!identical(previous, committed.tiles)) {
      _reconcileTextures(committed);
    }
    assert(invariantViolations(committed).isEmpty);
    assert(_texturesMatchState(committed));

    if (_kRecordRaster) {
      _drawnBlits.clear();
      _drawnGaps.clear();
      _firstFrameDrawn = false;
    }
    _drawBlits(canvas, step.frame.blits);
    _drawGaps(canvas, step.frame.gaps, c);
    return plan != null;
  }

  /// Dispose every texture [state]'s tile list no longer names. A texture is
  /// live iff a tile carries its id, so the state is the single source of
  /// truth and a texture dropped anywhere in the core (eviction, generation
  /// reset, splice) frees here, on that frame. [_executeBake] has already filed
  /// the frame's own bake, whose id the committed tile carries.
  void _reconcileTextures(CacheState state) {
    final live = {for (final s in state.tiles) s.textureId};
    for (final id in _images.keys.toList()) {
      if (live.contains(id)) continue;
      _images.remove(id)!.dispose();
    }
  }

  /// Debug-only: every tile owns a live texture and no texture is orphaned.
  /// This checks the reconcile shortcut in [paint] against the map.
  bool _texturesMatchState(CacheState state) {
    final ids = {for (final s in state.tiles) s.textureId};
    return ids.length == state.tiles.length &&
        ids.every(_images.containsKey) &&
        _images.length == ids.length;
  }

  /// Rasterize one planned range and file it under the ID allocated by the
  /// pure step. The image ceil-rounds the exact logical content width; blits
  /// sample only the content box, not that dead trailing column.
  void _executeBake(BakePlan plan, int textureId, TileViewConfig c) {
    final cc = c.config;
    final pps = cc.gw / cc.viewSpan;
    final int texW = math.max(1, ((plan.end - plan.start) * pps).ceil());
    final img = _bakeImage(
      ((texW + 2 * cc.hPad) * cc.dpr).ceil(),
      ((cc.gh + 2 * cc.vPad) * cc.dpr).ceil(),
      cc.dpr,
      (canvas) {
        canvas.translate(cc.hPad, cc.vPad);
        c.render(canvas, plan.start, plan.end);
      },
    );
    _images[textureId] = img;
  }

  /// Blit resolved rects (see [BlitRect] for what the fields hold).
  void _drawBlits(Canvas canvas, List<BlitRect> blits) {
    final paint = Paint()..filterQuality = kTileFilterQuality;
    for (final b in blits) {
      final src = Rect.fromLTWH(0, 0, b.sw, b.sh);
      final dst = Rect.fromLTWH(b.dx, b.dy, b.dw, b.dh);
      final clip = Rect.fromLTRB(b.clipL, b.clipB, b.clipR, b.clipT);
      canvas.save();
      canvas.clipRect(clip);
      canvas.drawImageRect(_images[b.tile.textureId]!, src, dst, paint);
      canvas.restore();
      if (_kRecordRaster) {
        _drawnBlits.add((tile: b.tile, src: src, dst: dst, clip: clip));
      }
    }
  }

  /// Vector-render the uncovered visible ranges (see the file header).
  void _drawGaps(Canvas canvas, List<GapRect> gaps, TileViewConfig c) {
    for (final g in gaps) {
      final clip = Rect.fromLTRB(g.clipL, g.clipB, g.clipR, g.clipT);
      canvas.save();
      canvas.clipRect(clip);
      canvas.translate(g.x, 0);
      c.render(canvas, g.start, g.end);
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
// Bake pump (shared repaint driver for the rolling tile bake)
// ---------------------------------------------------------------------------

/// Repaint driver for the rolling tile bake: baking is rationed to one bake
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
