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
// Vector-redrawing the whole plot every frame caused low framerates.
// Web has no engine raster cache: a ui.Picture re-executes on Skia every
// frame. Immutable sample ranges are baked once into GPU ui.Images and
// blitted; rebakes are smeared across frames at one bake per
// frame. A steady frame rate is preferred over fast refill: a burst of
// work in one frame shows up as a stutter. A segment that cannot blit
// (see _isBlittable in segmented_cache_functional.dart) draws nothing and
// refills only via the sweep; genuinely uncovered ranges (live-edge sliver,
// pan/zoom exposures) are the only full vector-draw paths.
//
// EVERY decision the cache makes lives in the functional core
// (segmented_cache_functional.dart): geometry, staleness, bake planning,
// blit/gap rect resolution. One frame is three pure transitions around one
// impure measurement (see that file's header):
//   prepareFrame -> planBakes -> [this file rasterizes] -> applyBakes
//   -> rasterPlan -> [this file draws]
// This file owns the impure minimum: ui.Image creation and disposal, canvas
// calls, and bake scheduling (BakePump). It makes essentially no decisions;
// if a branch appears here, it is a decision leak and belongs in the core.
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
//
// Fold-window invariant: a bake never covers samples outside the window the
// frame's Y-range was folded from (the cache's covStart..covEnd, computed as
// the same floor/ceil of the same window the painters fold their extremes
// over). A bake renders under the frame's yMin..yMax; samples the fold
// doesn't cover land past valueToY < -vPad and are raster-clipped at the
// texture edge, and that cut is frozen into the texture -- no later blit
// correction or sweep restores texels that were never recorded. Segments
// may still STRADDLE the window edges from window motion; but a re-bake of
// one clamps its coverage into the window, dropping the out-of-fold fringe
// to a gap that vector-draws when panned back to and bakes under a fold
// that includes it. Both invariants are enforced by the assert in
// planBakes (functional core): the single choke point all bake decisions
// pass through.
// ---------------------------------------------------------------------------

/// Base padding (logical px) baked around a segment texture so AA stroke
/// bleed survives the image crop. Renderers that overshoot the segment
/// bounds (the graphs' one-block polyline join) pass a larger horizontal pad.
/// Not needed by the core (it only carries it through to [SegmentMeta]); the
/// renderers that pass it to [SegmentViewConfig] are the only readers.
const double kSegmentImagePad = 4;

/// [FilterQuality.none] showed gaps and seams in testing; bilinear does
/// not.
const FilterQuality kSegmentFilterQuality = FilterQuality.low;

/// Renders samples [start, end) mapped to x in [0, ~texW) at the plot's
/// current y-mapping. Called both to bake segment textures and to draw
/// uncovered gaps directly to the frame canvas. Returns the logical px the
/// content occupies (x in [0, contentW) after the hPad translate); the
/// blit's x-scale reference. At most the allocated texW.
typedef SegmentRenderer =
    double Function(Canvas canvas, int start, int end, int texW);

/// One frame of inputs for [SegmentedGraphCache.paint]: the core's
/// [CacheConfig] (plot geometry, data/config identity, sample domain and bake
/// horizon, texture padding -- see [CacheConfig] and the live-edge invariant
/// in the file header) plus the one impure input, the vector renderer.
///
/// The config is EMBEDDED rather than flattened so [CacheConfig] stays the
/// single field list: a flattened copy here would compile after a field was
/// added on one side only, silently dropping it.
typedef SegmentViewConfig = ({CacheConfig config, SegmentRenderer render});

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

/// The impure shell over the functional core (see both file headers): owns
/// the textures (textureId -> ui.Image), executes the bake job [planBakes]
/// emits, and rasterizes [rasterPlan].
class SegmentedGraphCache {
  CacheState _state = CacheState.empty();

  /// Textures keyed by [SegmentMeta.textureId]. Metas are plain values
  /// (copies are harmless); the id is what names a texture.
  /// [prepareFrame]/[planBakes] report superseded metas as drops; their
  /// images are disposed here on the frame they drop out.
  final Map<int, ui.Image> _images = {};

  /// Serial source for [SegmentMeta.textureId]; never reused, so a stale id
  /// can never alias a live texture.
  int _nextTextureId = 0;

  void clear() {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    _state = _state.withSegments(const []);
  }

  void dispose() => clear();

  /// The rects the last [paint] drew, for tests. Blits are otherwise
  /// unobservable: the harness can see `render` calls but a blit is a
  /// `drawImageRect`, so nothing could assert the blit affine (the scale,
  /// offset and clip that shipped the historically visible bugs) without
  /// decoding pixels. Null until the first frame.
  @visibleForTesting
  ({List<BlitRect> blits, List<GapRect> gaps})? debugLastRaster;

  /// Bring the cache up to date for the frame [c] and blit it: apply
  /// generation/config changes, evict segments far outside the view, spend
  /// at most one segment (re)bake, then blit the cached segments for the
  /// window and vector-draw the uncovered gaps up to totalSamples.
  ///
  /// Config identity is split in three (see the file header for the model):
  /// generation clears the cache on change; destructiveKey (unit,
  /// calibration, tares) suppresses blitting of mismatched segments;
  /// remapKey (channels) keeps them blitting. Both kinds of mismatch are
  /// re-baked by the rolling rightmost-first sweep, so a config change never
  /// costs more than one bake per call.
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
    final env = cacheEnvFor(c.config);
    final prepared = prepareFrame(_state, env);
    final plan = planBakes(prepared.state, env);

    for (final m in [...prepared.drops, ...plan.drops]) {
      _images.remove(m.textureId)?.dispose();
    }

    // The impure measurement: rasterize the bake the core decided on. The
    // core never sees the texture, only the textureId it is filed under.
    final job = plan.job;
    final baked = job == null ? null : _executeBake(job, env, c);
    final committed = applyBake(
      prepared.state,
      env,
      plan,
      baked?.contentW ?? 0,
      _nextTextureId++,
    );
    if (baked != null) _images[committed.baked!.textureId] = baked.image;
    _state = committed.state;
    assert(invariantViolations(_state).isEmpty);
    assert(_texturesMatchState());

    final raster = rasterPlan(_state, env);
    debugLastRaster = raster;
    _drawBlits(canvas, raster.blits, env);
    _drawGaps(canvas, raster.gaps, c);
    return job != null;
  }

  /// Debug-only: every segment owns a live texture and no texture is
  /// orphaned. The core treats metas as values, so this is the invariant
  /// that keeps the map and the segment list in step.
  bool _texturesMatchState() {
    final ids = {for (final s in _state.segments) s.textureId};
    return ids.length == _state.segments.length &&
        ids.every(_images.containsKey) &&
        _images.length == ids.length;
  }

  /// Rasterize one [job] with the frame's render closure, sized to the
  /// range's current on-screen width so its blit starts at scale ~1.
  ({ui.Image image, double contentW}) _executeBake(
    BakeJob job,
    CacheEnv env,
    SegmentViewConfig c,
  ) {
    final int texW = math.max(1, ((job.end - job.start) * env.pps).ceil());
    double contentW = texW.toDouble();
    final cc = c.config;
    final img = _bakeImage(
      ((texW + 2 * cc.hPad) * cc.dpr).ceil(),
      ((cc.gh + 2 * cc.vPad) * cc.dpr).ceil(),
      cc.dpr,
      (canvas) {
        canvas.translate(cc.hPad, cc.vPad);
        contentW = c.render(canvas, job.start, job.end, texW);
      },
    );
    return (image: img, contentW: contentW);
  }

  /// Blit resolved rects; clip is the view bounds horizontally and the
  /// shared vPad band vertically (see [BlitRect]).
  void _drawBlits(Canvas canvas, List<BlitRect> blits, CacheEnv env) {
    final paint = Paint()..filterQuality = kSegmentFilterQuality;
    for (final b in blits) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(
          b.clipL,
          -b.seg.vPad,
          b.clipR,
          env.config.gh + b.seg.vPad,
        ),
      );
      canvas.drawImageRect(
        _images[b.seg.textureId]!,
        Rect.fromLTWH(0, 0, b.sw, b.sh),
        Rect.fromLTWH(b.dx, b.dy, b.dw, b.dh),
        paint,
      );
      canvas.restore();
    }
  }

  /// Vector-render the uncovered visible ranges (see the file header).
  void _drawGaps(Canvas canvas, List<GapRect> gaps, SegmentViewConfig c) {
    for (final g in gaps) {
      canvas.save();
      // The floored coverage start can put a gap's left edge up to one
      // sample-pixel left of the plot area; the translate keeps the content
      // mapping exact, so the clip is what gets clamped.
      final cc = c.config;
      canvas.clipRect(
        Rect.fromLTRB(
          math.max(g.x, 0.0),
          -cc.vPad,
          math.min(g.x + g.w, cc.gw),
          cc.gh + cc.vPad,
        ),
      );
      canvas.translate(g.x, 0);
      c.render(canvas, g.start, g.end, math.max(1, g.w.ceil()));
      canvas.restore();
    }
  }
}

// ---------------------------------------------------------------------------
// Bake pump (shared repaint driver for the rolling segment bake)
// ---------------------------------------------------------------------------

/// Repaint driver for the rolling segment bake: baking is rationed to one
/// bake per frame, so when work remains a painter calls
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
