import 'dart:math' as math;

// ---------------------------------------------------------------------------
// Segmented graph cache: functional core
//
// EVERY decision SegmentedGraphCache makes is computed here, as pure
// functions over value types. The raster shell (segmented_cache.dart) owns
// the impure minimum: ui.Image creation, canvas calls, image disposal, and
// bake scheduling. Nothing in this file may have side effects: no dart:ui,
// no clocks, no randomness, no scheduling. This file must never import the
// shell; the shell imports us.
//
// One frame is three pure transitions around one impure measurement:
//
//   (state, env) --prepareFrame--> state' + evicted metas
//   state'       --planBakes-----> at most one job + drops
//   [shell rasterizes the job, reading the render closure]
//   (state', job, contentW) --applyBake--> state'' + the meta it produced
//   state''      --rasterPlan----> blit rects + gap rects to draw
//
// State objects are treated as immutable: every function returns a new
// [CacheState] sharing the unchanged [SegmentMeta] instances. Metas are plain
// values (a copy is harmless); [SegmentMeta.textureId] is what names the
// shell's texture.
//
// The design context, staleness model, and both coverage invariants (live-
// edge bake horizon, fold-window containment) are documented in the shell
// file's header. The invariants are enforced here: [planBakes] asserts
// fold-window and horizon containment of every job it emits -- the single
// choke point all bake decisions pass through -- and [invariantViolations]
// states the segment-list invariant in executable form for asserts and
// tests.
// ---------------------------------------------------------------------------

/// [List] equality without the flutter/foundation import, so this file
/// stays pure-Dart and testable under plain `dart test`.
bool _keyEq(List<Object?> a, List<Object?> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Target on-screen width (logical px) of one baked segment texture.
const double kSegmentTargetPx = 200;

/// Max relative scale drift (horizontal or vertical) a visible segment may
/// accumulate before its rolling re-render. 0.08 is an educated guess:
/// unbounded drift visibly smears, but the acceptable range is wide; loose
/// enough that the one-bake-per-frame sweep keeps up.
const double kMaxSegmentDrift = 0.08;

/// Nominal baked line height (stroke + AA, logical px): the constant term
/// the corrective vertical blit stretch multiplies (see [_isBlittable]).
const double kBakedLinePx = 2.0;

/// Max fraction of the plot height a vertically stretched baked line may
/// occupy before the segment's blit is suppressed (see [_isBlittable]):
/// past it, the stretch -- e.g. a channel switch-off collapsing the Y-range
/// onto a quiet channel -- reads as a screen-filling smear, and the range
/// draws nothing until re-baked.
const double kMaxBlitLineFraction = 0.25;

/// Min on-screen width (logical px) of an uncovered range before a bake is
/// spent on it. Narrower gaps -- e.g. the live-edge sliver -- are drawn as
/// vectors every frame until they outgrow this.
const double kSegmentGapBakePx = 40;

/// Cached segments more than this many target-widths outside the view are
/// evicted; a segment is kSegmentTargetPx * dpr * plotHeight * dpr * 4 bytes
/// (a few MB on a tall graph at dpr 2), so the cache cannot be unbounded.
const int kSegmentEvictionMargin = 8;

/// Everything about one cached segment except its texture. The raster shell
/// owns textureId -> ui.Image; metas are plain values and may be copied
/// freely.
final class SegmentMeta {
  /// Identifies this segment's texture in the shell's map. Assigned by the
  /// shell (a serial), never derived from the meta's content: two metas with
  /// the same range can still own different textures, so range must not name
  /// a texture.
  final int textureId;

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

  /// Config keys at bake, compared against the state's current ones:
  /// [destructiveKey] (unit, calibration, tares) -- a mismatch means the
  /// content is wrong in kind or place and must never blit; [remapKey]
  /// (channels) -- a mismatch leaves it approximately right (a ghost) and
  /// blittable until the rolling sweep replaces it.
  final List<Object?> destructiveKey;
  final List<Object?> remapKey;

  /// Padding baked around the content (AA bleed / polyline overshoot).
  final double hPad;
  final double vPad;

  SegmentMeta({
    required this.textureId,
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
}

/// One frame of decision inputs: the plot geometry (gw x gh logical px at
/// dpr; samples viewStart..viewStart+viewSpan mapped to x in [0, gw), values
/// yMin..yMax mapped to the height), the data/config identity (generation +
/// keys; see the staleness model in the shell file header), the sample
/// domain and bake horizon, and texture padding (hPad, vPad). The shell's
/// wider SegmentViewConfig adds the one impure input, the render closure.
/// The core's view of one frame: plot geometry, data/config identity, sample
/// domain, texture padding. The shell's [SegmentViewConfig] embeds one of
/// these plus the render closure, so this is the ONLY field list: adding a
/// decision input here cannot be silently dropped by a parallel projection.
typedef CacheConfig = ({
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
});

/// The decision-relevant state of the whole cache: the segment metas and
/// the config stamps they are compared against. See the staleness model in
/// the shell file header.
final class CacheState {
  /// Metas ordered by [SegmentMeta.start], never overlapping (see
  /// [invariantViolations]): a refresh only ever retracts to the bake
  /// horizon, swallows abutting neighbors, or stops at the next segment's
  /// start ([_planRefresh]), so the list is a disjoint tiling of the covered
  /// ranges. Ranges between segments are gaps: vector-drawn or left blank
  /// until a bake covers them.
  final List<SegmentMeta> segments;

  /// The cache's current stamps; metas carry their own. A destructiveKey
  /// mismatch suppresses the blit; a remapKey/gh/dpr mismatch keeps
  /// blitting (ghost/shift) and is swept. gh/dpr are NOT destructive: the
  /// blit affine corrects for both. [generation] identifies the data
  /// stream itself; a change clears everything.
  final int generation;
  final double gh;
  final double dpr;
  final List<Object?> destructiveKey;
  final List<Object?> remapKey;

  CacheState({
    required this.segments,
    required this.generation,
    required this.gh,
    required this.dpr,
    required this.destructiveKey,
    required this.remapKey,
  });

  /// A cache that has never seen a frame: no segments, stamped from [c].
  /// [prepareFrame] takes a nullable state instead of a stamped sentinel, so
  /// "nothing yet" is not encoded in a magic generation/gh/dpr.
  factory CacheState.fresh(CacheConfig c) => CacheState(
    segments: const [],
    generation: c.generation,
    gh: c.gh,
    dpr: c.dpr,
    destructiveKey: List.of(c.destructiveKey),
    remapKey: List.of(c.remapKey),
  );

  CacheState withSegments(List<SegmentMeta> segments) => CacheState(
    segments: segments,
    generation: generation,
    gh: gh,
    dpr: dpr,
    destructiveKey: destructiveKey,
    remapKey: remapKey,
  );

  /// Adopt [c]'s config as the current stamps (see [_configDiffers]).
  /// Lists are copied, like the shell's historical _stampConfig: callers
  /// may reuse and mutate their key lists between frames.
  CacheState withStamps(CacheConfig c) => CacheState(
    segments: segments,
    generation: c.generation,
    gh: c.gh,
    dpr: c.dpr,
    destructiveKey: List.of(c.destructiveKey),
    remapKey: List.of(c.remapKey),
  );
}

/// The frame config plus the quantities derived from it once ([cacheEnvFor]),
/// so every decision reads the same derived values. [covStart]/[covEnd] are
/// the integer coverage (and fold) window; [viewStart] is its fractional
/// source and only shifts blit placement.
typedef CacheEnv = ({
  CacheConfig config,
  double pps, // logical px per sample
  int covStart,
  int covEnd,
  int targetSpan,
});

CacheEnv cacheEnvFor(CacheConfig c) {
  final double viewEnd = c.viewStart + c.viewSpan;
  return (
    config: c,
    pps: c.gw / c.viewSpan,
    // Coverage bookkeeping is integer: bakes and gap ranges are
    // sample-aligned (block anchoring). The fractional scroll offset only
    // shifts blit placement (see [rasterPlan]).
    covStart: c.viewStart.floor(),
    covEnd: viewEnd.ceil(),
    targetSpan: math.max(1, (kSegmentTargetPx / (c.gw / c.viewSpan)).round()),
  );
}

/// Whether the given config stamps differ from [state]'s. One check, two
/// candidates: the frame config (a bump disposes out-of-view segments in
/// [prepareFrame]) and a segment's bake stamps (a mismatch marks the
/// segment for the rolling re-bake in [_stalePlan]).
bool _configDiffers(
  List<Object?> destructiveKey,
  List<Object?> remapKey,
  double gh,
  double dpr,
  CacheState state,
) =>
    !_keyEq(destructiveKey, state.destructiveKey) ||
    !_keyEq(remapKey, state.remapKey) ||
    (gh - state.gh).abs() > 0.1 ||
    dpr != state.dpr;

/// Transition 1: apply generation/config changes and evict segments far
/// outside the view. Returns the new state and the metas whose textures the
/// shell must dispose.
///
/// [state] is null on the first frame: a fresh cache adopts the config's
/// stamps and matches nothing (no segments, no drops), which is the same
/// answer the stamped-sentinel version gave by accident.
///
/// On a generation change everything is dropped. On a config bump (see the
/// staleness model), segments outside the view are dropped so stale content
/// cannot resurrect on a later pan before the sweep reaches them; their
/// ranges vector-draw if panned back to.
({CacheState state, List<SegmentMeta> drops}) prepareFrame(
  CacheState? state,
  CacheEnv env,
) {
  final config = env.config;
  if (state == null) {
    return (state: CacheState.fresh(config), drops: const []);
  }
  final drops = <SegmentMeta>[];
  CacheState result;
  if (config.generation != state.generation) {
    drops.addAll(state.segments);
    result = CacheState.fresh(config);
  } else if (_configDiffers(
    config.destructiveKey,
    config.remapKey,
    config.gh,
    config.dpr,
    state,
  )) {
    final kept = <SegmentMeta>[];
    for (final s in state.segments) {
      if (s.end > env.covStart && s.start < env.covEnd) {
        kept.add(s);
      } else {
        drops.add(s);
      }
    }
    result = state.withStamps(config).withSegments(kept);
  } else {
    result = state;
  }

  final int margin = kSegmentEvictionMargin * env.targetSpan;
  final afterEvict = <SegmentMeta>[];
  bool evicted = false;
  for (final s in result.segments) {
    if (s.end >= env.covStart - margin && s.start <= env.covEnd + margin) {
      afterEvict.add(s);
    } else {
      drops.add(s);
      evicted = true;
    }
  }
  return (
    state: evicted ? result.withSegments(afterEvict) : result,
    drops: drops,
  );
}

/// Uncovered sub-ranges of [covStart, min(covEnd, domainEnd)). Coverage is
/// purely geometric: a segment counts as covered even when it may not blit
/// (its pixels draw nothing -- see the shell file header).
List<(int, int)> _gaps(
  List<SegmentMeta> segments,
  int covStart,
  int covEnd,
  int domainEnd,
) {
  final end = math.min(covEnd, domainEnd);
  final gaps = <(int, int)>[];
  int covered = covStart;
  for (final s in segments) {
    if (covered >= end) break;
    if (s.start > covered) gaps.add((covered, math.min(s.start, end)));
    covered = math.max(covered, s.end);
  }
  if (covered < end) gaps.add((covered, end));
  return gaps;
}

/// One bake decision: replace working-list segments [from]..[to] (inclusive)
/// with a bake of samples [start, end).
typedef BakeJob = ({int from, int to, int start, int end});

/// One frame's bake decision: at most one bake (see [planBakes]).
///   * [job] -- the bake to rasterize, or null for a quiet frame;
///   * [base] -- the segment list [BakeJob.from]/[BakeJob.to] index: the
///     frame's list minus any horizon-receded segments the sweep retired;
///   * [drops] -- metas whose textures are superseded (the splice victims and
///     the retired segments). Disposal only; never used for placement.
/// There is deliberately no post-bake layout: the shell asks [applyBake] for
/// the meta the job produced, so nothing has to predict the rendered width
/// ahead of the render.
typedef BakePlan = ({
  BakeJob? job,
  List<SegmentMeta> base,
  List<SegmentMeta> drops,
});

/// Transition 2: choose this frame's (re)bake -- priority:
///   1. the widest visible gap past [kSegmentGapBakePx];
///   2. the rightmost visible stale segment (see [_stalePlan]).
///
/// One bake per frame: bakes are rationed to keep a steady frame rate (see
/// the shell file header), so a multi-job plan would be unreachable code
/// with a state-space of its own.
///
/// The fold-window and bake-horizon invariants (shell file header) are
/// asserted here: this is the single choke point all bake decisions pass
/// through, so the invariants hold for every (re)bake path.
BakePlan planBakes(CacheState state, CacheEnv env) {
  final work = List<SegmentMeta>.of(state.segments);
  final drops = <SegmentMeta>[];
  BakeJob? job = _bakeWidestGap(work, env);
  if (job == null) {
    final refresh = _refreshStaleSegment(work, state, env);
    // [work] is what the job's indices refer to after this scan retired the
    // horizon-receded metas, so it is the plan's base; those metas ride
    // [drops] for disposal only.
    drops.addAll(refresh.drops);
    job = refresh.job;
  }
  if (job == null) return (job: null, base: work, drops: drops);
  assert(
    job.start >= env.covStart &&
        job.end <= env.covEnd &&
        job.end <= env.config.bakeableSamples,
    'bake [${job.start}, ${job.end}) outside fold window '
    '[${env.covStart}, ${env.covEnd}) or past the bake horizon '
    '${env.config.bakeableSamples}',
  );
  drops.addAll(work.sublist(job.from, job.to + 1));
  return (job: job, base: work, drops: drops);
}

/// The meta a [job] produced, given the rendered [contentW] and the
/// [textureId] the shell assigned it.
SegmentMeta _jobMeta(
  BakeJob job,
  CacheState state,
  CacheEnv env,
  double contentW,
  int textureId,
) {
  final c = env.config;
  return SegmentMeta(
    textureId: textureId,
    start: job.start,
    end: job.end,
    contentW: math.max(contentW, 0.001),
    yMin: c.yMin,
    yMax: c.yMax,
    gh: c.gh,
    dpr: c.dpr,
    destructiveKey: state.destructiveKey,
    remapKey: state.remapKey,
    hPad: c.hPad,
    vPad: c.vPad,
  );
}

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
///
/// The returned job's [BakeJob.from]/[BakeJob.to] mark the absorbed
/// segments to drop; a job with from == at is a plain insert (to == at - 1).
BakeJob? _bakeWidestGap(List<SegmentMeta> work, CacheEnv env) {
  (int, int)? bakeGap;
  double widestPx = kSegmentGapBakePx;
  for (final g in _gaps(
    work,
    env.covStart,
    env.covEnd,
    env.config.bakeableSamples,
  )) {
    final double w = (g.$2 - g.$1) * env.pps;
    if (w > widestPx) {
      widestPx = w;
      bakeGap = g;
    }
  }
  if (bakeGap == null) return null;

  final int end = bakeGap.$2;
  int start = math.max(bakeGap.$1, end - env.targetSpan);
  if ((start - bakeGap.$1) * env.pps <= kSegmentGapBakePx) {
    start = bakeGap.$1; // swallow the orphaned remainder
  }
  assert(end > start); // non-empty gap and targetSpan >= 1 keep start < end

  // Insertion point: first segment starting inside/after the bake range.
  int at = 0;
  while (at < work.length && work[at].start < start) {
    at++;
  }
  // Absorb whole left neighbors while the merged bake stays within one
  // target width, so the live-edge segment grows in place (one bake per
  // sliver) instead of accumulating sliver-wide strips.
  int from = at;
  while (from > 0 &&
      (end - work[from - 1].start) * env.pps <= kSegmentTargetPx) {
    from--;
  }
  if (from < at) start = work[from].start;
  // An absorbed neighbor may straddle the left view edge; the fold-window
  // invariant caps the bake at the window, dropping the neighbor's
  // out-of-fold fringe to an out-of-view gap.
  start = math.max(start, env.covStart);

  return (from: from, to: at - 1, start: start, end: end);
}

/// One [_refreshStaleSegment] scan: the bake to spend, plus every visible
/// segment the receded bake horizon has fully overtaken, dropped from
/// [work] during the scan.
typedef _RefreshOutcome = ({BakeJob? job, List<SegmentMeta> drops});

/// Priority 2: re-bake the rightmost visible stale segment (see
/// [_stalePlan]), replacing the range [_planRefresh] computes. The scan
/// continues left past horizon-receded drops, so one frame can drop
/// several and still bake.
_RefreshOutcome _refreshStaleSegment(
  List<SegmentMeta> work,
  CacheState state,
  CacheEnv env,
) {
  final drops = <SegmentMeta>[];
  for (int i = work.length - 1; i >= 0; i--) {
    final s = work[i];
    if (s.end <= env.covStart || s.start >= env.covEnd) continue;
    final p = _stalePlan(work, state, i, env);
    if (p == null) continue;
    if (p.end <= p.start) {
      drops.add(work.removeAt(i));
      continue;
    }
    return (
      job: (from: p.from, to: p.to, start: p.start, end: p.end),
      drops: drops,
    );
  }
  return (job: null, drops: drops);
}

/// One refresh outcome: replace working-list segments [from]..[to]
/// (inclusive) with a single bake of [start, end). A no-op refresh is the
/// identity plan: [from] == [to], [start] == the segment's own start,
/// [end] == its own (horizon- and window-clamped) end.
typedef _RefreshPlan = ({int from, int to, int start, int end});

/// Whether [s] may blit under the current Y-mapping: the destructive key
/// must match, and the corrective vertical stretch must keep the baked
/// line ([kBakedLinePx] at bake) within [kMaxBlitLineFraction] of the plot
/// height. One-sided: shrinking only sharpens, but a large stretch -- e.g.
/// the Y-range collapsing onto a quiet channel -- smears the segment's line
/// across the screen. A suppressed segment is kept, not disposed: a
/// Y-range snap-back makes it blittable again.
bool _isBlittable(SegmentMeta s, CacheState state, CacheEnv env) {
  if (!_keyEq(s.destructiveKey, state.destructiveKey)) return false;
  return _blitYScale(s, env.config) * kBakedLinePx <=
      env.config.gh * kMaxBlitLineFraction;
}

/// The corrective vertical scale a blit of [s] applies: baked value-range
/// drift times the plot-height ratio since the bake.
double _blitYScale(SegmentMeta s, CacheConfig c) =>
    (s.yMax - s.yMin) / (c.yMax - c.yMin) * (c.gh / s.gh);

/// The refresh plan for [i] if it is stale, else null:
///   * config-stale -- baked under outdated keys/gh/dpr;
///   * drift-stale -- x- or y-scale drift past [kMaxSegmentDrift];
///   * size-stale -- past two targets on screen or under half a target,
///     AND [_planRefresh] would change the geometry. A size outlier whose
///     refresh can only reproduce its own range is left alone: re-baking
///     identical pixels every frame is a bake-pump-fed busy loop (the
///     quiescence invariant -- every bake moves a boundary or updates
///     content, then the scan goes quiet).
///
/// Config and drift staleness take whatever plan [_planRefresh] computes,
/// including an absorbed left neighbor: two tiles that both need re-baking
/// are cheaper merged into one bake than refreshed in two frames.
_RefreshPlan? _stalePlan(
  List<SegmentMeta> work,
  CacheState state,
  int i,
  CacheEnv env,
) {
  final s = work[i];
  final p = _planRefresh(work, i, env);
  if (_configDiffers(s.destructiveKey, s.remapKey, s.gh, s.dpr, state)) {
    return p;
  }
  final double w = (s.end - s.start) * env.pps;
  final double xScale = w / s.contentW;
  final double yScale = (s.yMax - s.yMin) / (env.config.yMax - env.config.yMin);
  if (math.max((1 - xScale).abs(), (1 - yScale).abs()) > kMaxSegmentDrift) {
    return p;
  }
  final bool sizeOutlier = w > 2 * kSegmentTargetPx || w < kSegmentTargetPx / 2;
  // Compare against the identity plan clamped by the SAME helper
  // [_planRefresh] uses, or a straddling size outlier would read its own
  // clamped shape as a geometry change and re-bake every frame.
  return sizeOutlier &&
          p != _clampPlan((from: i, to: i, start: s.start, end: s.end), env)
      ? p
      : null;
}

/// Where a refresh of [i] would bake and which segments it would replace
/// (see [_RefreshPlan]), independent of why. Disjointness (see
/// [invariantViolations]) is what makes this a partition operation rather
/// than range arithmetic: the refresh never crosses the next segment's
/// start, and swallows neighbors only whole. The bake range is clamped to
/// the fold window ([CacheEnv.covStart], [CacheEnv.covEnd]) throughout: the
/// invariant in the shell file header.
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
/// `pps/2` px off [kSegmentTargetPx] from the target-span rounding) and
/// merges at 1.5 targets, so nothing is born already past a size
/// threshold -- the birth side of the quiescence invariant.
_RefreshPlan _planRefresh(List<SegmentMeta> work, int i, CacheEnv env) {
  final int bakeable = env.config.bakeableSamples;
  final s = work[i];
  // Retract to the fold window as well as the horizon: [s] may straddle
  // the right view edge from window motion.
  final int end = math.min(s.end, math.min(bakeable, env.covEnd));
  if (end <= s.start) {
    return (from: i, to: i, start: s.start, end: end);
  }
  if ((end - s.start) * env.pps > 2 * kSegmentTargetPx &&
      end - env.targetSpan > s.start) {
    return _clampPlan((
      from: i,
      to: i,
      start: end - env.targetSpan,
      end: end,
    ), env);
  }
  int from = i;
  int start = s.start;
  while (from > 0 &&
      work[from - 1].end == start &&
      (end - work[from - 1].start) * env.pps <= 1.5 * kSegmentTargetPx) {
    from--;
    start = work[from].start;
  }
  int mergedEnd = end;
  int to = i;
  if ((mergedEnd - start) * env.pps < kSegmentTargetPx / 2) {
    final int uncoveredLimit = math.min(
      to + 1 < work.length ? work[to + 1].start : bakeable,
      bakeable,
    );
    mergedEnd = math.max(
      mergedEnd,
      math.min(start + env.targetSpan, uncoveredLimit),
    );
    if ((mergedEnd - start) * env.pps < kSegmentTargetPx / 2 &&
        to + 1 < work.length &&
        work[to + 1].start == mergedEnd &&
        (work[to + 1].end - start) * env.pps <= 1.5 * kSegmentTargetPx) {
      to++;
      mergedEnd = work[to].end;
    }
  }
  return _clampPlan((from: from, to: to, start: start, end: mergedEnd), env);
}

/// Confine a refresh plan's bake range to the fold window and the bake
/// horizon, the two coverage invariants in the shell file header. The only
/// place those clamps are written: a swallowed LEFT neighbor may straddle the
/// left view edge, and a swallowed RIGHT neighbor (or a grown end) may reach
/// the right edge -- or past a RECEDED horizon, which neighbors are never
/// trimmed to. Out-of-window fringes drop to gaps.
_RefreshPlan _clampPlan(_RefreshPlan p, CacheEnv env) => (
  from: p.from,
  to: p.to,
  start: math.max(p.start, env.covStart),
  end: math.min(p.end, math.min(env.covEnd, env.config.bakeableSamples)),
);

/// Transition 3: commit the frame's bake. Returns the new state plus the
/// meta the job produced (null for a quiet frame), so the shell can pair the
/// meta with the texture it just rasterized. [contentW] is the rendered
/// width: the only baked output any later decision reads back (as the blit
/// x-scale reference).
///
/// [BakeJob.from]/[BakeJob.to] index [BakePlan.base], which the planner
/// built by retiring [BakePlan.drops] from the frame's list; the splice
/// therefore lands on the same positions the planner computed.
({CacheState state, SegmentMeta? baked}) applyBake(
  CacheState state,
  CacheEnv env,
  BakePlan plan,
  double contentW,
  int textureId,
) {
  final job = plan.job;
  if (job == null) return (state: state.withSegments(plan.base), baked: null);
  final meta = _jobMeta(job, state, env, contentW, textureId);
  final segments = <SegmentMeta>[
    ...plan.base.sublist(0, job.from),
    meta,
    ...plan.base.sublist(job.to + 1),
  ];
  return (state: state.withSegments(segments), baked: meta);
}

/// One blit with all geometry resolved (translate/clip/drawImageRect
/// operands), in logical px: clip to [clipL]..[clipR] horizontally and
/// -seg.vPad..config.gh+seg.vPad vertically, then draw the source content
/// rect (0,0 to [sw],[sh] physical px) into the [dx]/[dy]/[dw]/[dh]
/// destination. See the blit derivation in the shell (history): texture x-px u covers sample start + u*(end-start)/contentW,
/// landing today at affine x, and valueToY is affine in (yMin, yMax), so a
/// y scale+offset corrects for range AND plot-height changes since the
/// bake. Per-channel offsets (tares) are NOT corrected: one segment
/// composites every channel, so no single affine can hold per-channel
/// shifts -- tares ride the destructive key instead.
typedef BlitRect = ({
  SegmentMeta seg,
  double clipL,
  double clipR,
  double dx,
  double dy,
  double dw,
  double dh,
  double sw,
  double sh,
});

/// One uncovered visible range to vector-render, with its resolved
/// placement: clip to [x]..[x]+[w] (clamped to the plot bounds) and render
/// samples [start, end) after a translate([x], 0).
typedef GapRect = ({int start, int end, double x, double w});

/// Transition 4: resolve what the frame rasterizes -- one [BlitRect] per
/// visible blittable segment and one [GapRect] per uncovered visible range.
({List<BlitRect> blits, List<GapRect> gaps}) rasterPlan(
  CacheState state,
  CacheEnv env,
) {
  final c = env.config;
  final blits = <BlitRect>[];
  for (final s in state.segments) {
    if (!_isBlittable(s, state, env)) continue;
    final double x1 = (s.start - c.viewStart) * env.pps;
    final double x2 = (s.end - c.viewStart) * env.pps;
    // Segments are disjoint (see [invariantViolations]), so one screen x
    // has at most one blit; the clip is just the view bounds.
    final double clipL = math.max(x1, 0.0);
    final double clipR = math.min(x2, c.gw);
    if (clipR <= clipL) continue;

    final double xs = (x2 - x1) / s.contentW;
    final double ys = _blitYScale(s, c);
    // Where the segment's top content row (value s.yMax) lands today.
    final double yTop = c.gh * (1 - (s.yMax - c.yMin) / (c.yMax - c.yMin));

    blits.add((
      seg: s,
      clipL: clipL,
      clipR: clipR,
      dx: x1 - s.hPad * xs,
      dy: yTop - s.vPad * ys,
      dw: (s.contentW + 2 * s.hPad) * xs,
      dh: (s.gh + 2 * s.vPad) * ys,
      // Source is the CONTENT rect (content + pads), not the image bounds:
      // the dead ceil column would otherwise bake a small scale error into
      // every blit, blurring even identity mappings.
      sw: (s.contentW + 2 * s.hPad) * s.dpr,
      sh: (s.gh + 2 * s.vPad) * s.dpr,
    ));
  }
  final gaps = <GapRect>[
    for (final (gs, ge) in _gaps(
      state.segments,
      env.covStart,
      env.covEnd,
      c.totalSamples,
    ))
      (
        start: gs,
        end: ge,
        x: (gs - c.viewStart) * env.pps,
        w: (ge - gs) * env.pps,
      ),
  ];
  return (blits: blits, gaps: gaps);
}

/// The segment-list invariant in executable form: ordered by
/// [SegmentMeta.start], non-empty ranges, no overlaps (gaps are fine).
/// Every transition preserves it; asserts and invariant-testing harnesses
/// call it on states and let it name the violation.
List<String> invariantViolations(CacheState state) {
  final violations = <String>[];
  final segs = state.segments;
  for (int k = 0; k < segs.length; k++) {
    if (segs[k].end <= segs[k].start) {
      violations.add(
        'segment $k has empty range [${segs[k].start}, ${segs[k].end})',
      );
    }
    if (k > 0 && segs[k - 1].end > segs[k].start) {
      violations.add(
        'segments ${k - 1} and $k overlap: '
        '[${segs[k - 1].start}, ${segs[k - 1].end}) vs '
        '[${segs[k].start}, ${segs[k].end})',
      );
    }
  }
  return violations;
}
