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
// One frame is four pure transitions around one impure measurement:
//
//   (state, env) --prepareFrame--> state'
//   state'       --planBakes-----> at most one plan, or null for a quiet frame
//   [shell rasterizes the plan, reading the render closure]
//   (state', plan, bake) --applyBake--> state'' + the meta it produced
//   state''      --rasterPlan----> blit rects + gap rects to draw
//
// State objects are treated as immutable: every function returns a new
// [CacheState] sharing the unchanged [SegmentMeta] instances. Metas are plain
// values (a copy means the same segment); [SegmentMeta.textureId] is what
// names a texture, and the shell frees textures by matching live ids against
// the segment list.
//
// The design context, staleness model, and both coverage invariants (live-
// edge bake horizon, fold-window containment) are documented in the shell
// file's header. The invariants are enforced here: [planBakes] asserts
// fold-window and horizon containment of every bake it plans -- the single
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
/// owns textureId -> ui.Image; metas are plain values, so every decision that
/// compares or matches segments (drops, splice victims, blits) can do it by
/// value instead of by identity.
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

/// The core's view of one frame: plot geometry (gw x gh logical px at dpr;
/// samples viewStart..viewStart+viewSpan mapped to x in [0, gw), values
/// yMin..yMax mapped to the height), data/config identity (generation + keys;
/// see the staleness model in the shell file header), the sample domain and
/// bake horizon, and texture padding (hPad, vPad). The shell's
/// [SegmentViewConfig] embeds one of these plus the one impure input, the
/// render closure, so this is the ONLY field list: a decision input added here
/// cannot be silently dropped by a parallel projection.
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
  /// [invariantViolations]): a bake splices into a contiguous run of them (see
  /// [BakePlan]) and never crosses the next segment's start (see
  /// [_planRefresh]), so the list is a disjoint tiling of the covered ranges.
  /// Ranges between segments are gaps: vector-drawn or left blank until a bake
  /// covers them.
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

  /// The one field list; [withSegments] and [withStamps] are the only ways to
  /// derive a state, so a field added here cannot be forgotten by one of them.
  const CacheState._({
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
  factory CacheState.fresh(CacheConfig c) => CacheState._(
    segments: const [],
    generation: c.generation,
    gh: c.gh,
    dpr: c.dpr,
    destructiveKey: List.of(c.destructiveKey),
    remapKey: List.of(c.remapKey),
  );

  CacheState withSegments(List<SegmentMeta> segments) => CacheState._(
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
  CacheState withStamps(CacheConfig c) => CacheState._(
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
/// outside the view. Returns the new state; segments it dropped are simply
/// absent from it, which is what the shell frees textures from (see
/// [_reconcileTextures]).
///
/// [state] is null on the first frame: a fresh cache adopts the config's
/// stamps and matches nothing (no segments).
///
/// On a generation change everything is dropped. On a config bump (see the
/// staleness model), segments outside the view are dropped so stale content
/// cannot resurrect on a later pan before the sweep reaches them; their
/// ranges vector-draw if panned back to.
CacheState prepareFrame(CacheState? state, CacheEnv env) {
  final config = env.config;
  if (state == null) return CacheState.fresh(config);
  final result = _restamp(state, env);
  final int margin = kSegmentEvictionMargin * env.targetSpan;
  final kept = [
    for (final s in result.segments)
      if (s.end >= env.covStart - margin && s.start <= env.covEnd + margin) s,
  ];
  return kept.length == result.segments.length
      ? result
      : result.withSegments(kept);
}

/// [state] under the frame's stamps: empty on a generation change, restricted
/// to the visible segments on a config bump (the rest would only draw stale
/// content when panned back to), unchanged otherwise.
CacheState _restamp(CacheState state, CacheEnv env) {
  final config = env.config;
  if (config.generation != state.generation) return CacheState.fresh(config);
  if (!_configDiffers(
    config.destructiveKey,
    config.remapKey,
    config.gh,
    config.dpr,
    state,
  )) {
    return state;
  }
  return state.withStamps(config).withSegments([
    for (final s in state.segments)
      if (s.end > env.covStart && s.start < env.covEnd) s,
  ]);
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

/// One bake decision: replace segments [from]..[to] (inclusive) of the state
/// [planBakes] returns -- NOT of the state passed in, which still holds the
/// segments the receded horizon retired -- with a bake of samples
/// [start, end). One record for both kinds of decision: a refresh is a plan
/// whose range it computed itself, and a gap fill one whose range came from an
/// uncovered range.
typedef BakePlan = ({int from, int to, int start, int end});

/// Transition 2: retire the segments the receded horizon has overtaken, then
/// choose this frame's (re)bake -- priority:
///   1. the widest visible gap past [kSegmentGapBakePx];
///   2. the rightmost visible stale segment (see [_stalePlan]).
///
/// Returns the state the plan indexes plus the plan (null for a quiet frame).
/// The retired segments are gone from that state, so the caller needs no
/// second list and no drop channel: which textures are live follows from the
/// segment list.
///
/// One bake per frame: bakes are rationed to keep a steady frame rate (see
/// the shell file header), so a multi-bake plan would be unreachable code
/// with a state-space of its own.
///
/// The fold-window and bake-horizon invariants (shell file header) are
/// asserted here: this is the single choke point all bake decisions pass
/// through, so the invariants hold for every (re)bake path.
({CacheState state, BakePlan? plan}) planBakes(CacheState state, CacheEnv env) {
  final planned = _retireReceded(state, env);
  final plan =
      _bakeWidestGap(planned.segments, env) ??
      _refreshStaleSegment(planned.segments, planned, env);
  if (plan == null) return (state: planned, plan: null);
  assert(
    plan.start >= env.covStart &&
        plan.end <= env.covEnd &&
        plan.end <= env.config.bakeableSamples,
    'bake [${plan.start}, ${plan.end}) outside fold window '
    '[${env.covStart}, ${env.covEnd}) or past the bake horizon '
    '${env.config.bakeableSamples}',
  );
  return (state: planned, plan: plan);
}

/// Retire the visible segments the receded bake horizon has fully overtaken
/// (see [_isReceded]). A pass of its own rather than part of the sweep, so the
/// retirement does not depend on which bake wins the frame: it is a
/// consequence of the horizon alone.
CacheState _retireReceded(CacheState state, CacheEnv env) {
  final kept = <SegmentMeta>[];
  for (int i = 0; i < state.segments.length; i++) {
    if (!_isReceded(state.segments, state, i, env)) {
      kept.add(state.segments[i]);
    }
  }
  return kept.length == state.segments.length
      ? state
      : state.withSegments(kept);
}

/// Whether the receded horizon has fully overtaken visible segment [i]: stale,
/// and the horizon-clamped refresh range is empty, so the sweep could only
/// drop it. A segment baked under a further-out horizon still covers samples
/// past it and keeps blitting; only one left with no range at all goes.
bool _isReceded(
  List<SegmentMeta> segments,
  CacheState state,
  int i,
  CacheEnv env,
) {
  final s = segments[i];
  if (s.end <= env.covStart || s.start >= env.covEnd) return false;
  final p = _stalePlan(segments, state, i, env);
  return p != null && p.end <= p.start;
}

/// The meta a [plan] produced, given the impure measurement the shell made for
/// it (see [BakeOutput]).
SegmentMeta _metaFor(
  BakePlan plan,
  CacheState state,
  CacheEnv env,
  BakeOutput output,
) {
  final c = env.config;
  return SegmentMeta(
    textureId: output.textureId,
    start: plan.start,
    end: plan.end,
    contentW: math.max(output.contentW, 0.001),
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
/// a sustained arrival rate above the one-bake-per-frame rate, left alignment
/// spends every bake at the exiting edge while the whole window vector-draws.
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
/// The returned plan's [BakePlan.from]/[BakePlan.to] mark the absorbed
/// segments to replace; a plan with from == at is a plain insert (to == at - 1).
BakePlan? _bakeWidestGap(List<SegmentMeta> segments, CacheEnv env) {
  (int, int)? bakeGap;
  double widestPx = kSegmentGapBakePx;
  for (final g in _gaps(
    segments,
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
  while (at < segments.length && segments[at].start < start) {
    at++;
  }
  // Absorb whole left neighbors while the merged bake stays within one
  // target width, so the live-edge segment grows in place (one bake per
  // sliver) instead of accumulating sliver-wide strips.
  int from = at;
  while (from > 0 &&
      (end - segments[from - 1].start) * env.pps <= kSegmentTargetPx) {
    from--;
  }
  if (from < at) start = segments[from].start;
  // An absorbed neighbor may straddle the left view edge; the fold-window
  // invariant caps the bake at the window, dropping the neighbor's
  // out-of-fold fringe to an out-of-view gap.
  start = math.max(start, env.covStart);

  return (from: from, to: at - 1, start: start, end: end);
}

/// Priority 2: re-bake the rightmost visible stale segment (see
/// [_stalePlan]), replacing the range [_planRefresh] computes. The scan
/// skips segments out of view, and skips an empty plan -- that is a
/// horizon-receded retirement, which [_retireReceded] already did -- so a
/// frame with nothing stale to re-bake returns null.
BakePlan? _refreshStaleSegment(
  List<SegmentMeta> segments,
  CacheState state,
  CacheEnv env,
) {
  for (int i = segments.length - 1; i >= 0; i--) {
    final s = segments[i];
    if (s.end <= env.covStart || s.start >= env.covEnd) continue;
    final p = _stalePlan(segments, state, i, env);
    if (p == null || p.end <= p.start) continue;
    return p;
  }
  return null;
}

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
BakePlan? _stalePlan(
  List<SegmentMeta> segments,
  CacheState state,
  int i,
  CacheEnv env,
) {
  final s = segments[i];
  final p = _planRefresh(segments, i, env);
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
/// (see [BakePlan]), independent of why. Disjointness (see
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
BakePlan _planRefresh(List<SegmentMeta> segments, int i, CacheEnv env) {
  final int bakeable = env.config.bakeableSamples;
  final s = segments[i];
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
      segments[from - 1].end == start &&
      (end - segments[from - 1].start) * env.pps <= 1.5 * kSegmentTargetPx) {
    from--;
    start = segments[from].start;
  }
  int mergedEnd = end;
  int to = i;
  if ((mergedEnd - start) * env.pps < kSegmentTargetPx / 2) {
    final int uncoveredLimit = math.min(
      to + 1 < segments.length ? segments[to + 1].start : bakeable,
      bakeable,
    );
    mergedEnd = math.max(
      mergedEnd,
      math.min(start + env.targetSpan, uncoveredLimit),
    );
    if ((mergedEnd - start) * env.pps < kSegmentTargetPx / 2 &&
        to + 1 < segments.length &&
        segments[to + 1].start == mergedEnd &&
        (segments[to + 1].end - start) * env.pps <= 1.5 * kSegmentTargetPx) {
      to++;
      mergedEnd = segments[to].end;
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
BakePlan _clampPlan(BakePlan p, CacheEnv env) => (
  from: p.from,
  to: p.to,
  start: math.max(p.start, env.covStart),
  end: math.min(p.end, math.min(env.covEnd, env.config.bakeableSamples)),
);

/// The only output of a bake that any later decision reads back: the rendered
/// content width (the blit's x-scale reference) and the texture the shell
/// filed it under. The shell constructs it from the impure measurement, so the
/// core never sees a texture and never predicts a width ahead of the render.
typedef BakeOutput = ({double contentW, int textureId});

/// This frame's bake: the plan the core chose, and the measurement the shell
/// made of it. One value because the two are only meaningful together -- a
/// plan with no output never finished rasterizing, and an output with no plan
/// was made for a bake nobody asked for -- so neither can be passed alone.
typedef FrameBake = ({BakePlan plan, BakeOutput output});

/// Transition 3: commit the frame's bake. [state] is what [planBakes]
/// returned, [bake] is what the shell measured for the plan (null for a quiet
/// frame). Returns the new state plus the meta the bake produced (null for a
/// quiet frame).
///
/// The splice indexes the state [planBakes] returned, which no longer holds
/// the segments a receded horizon retired, so the positions are the ones the
/// planner computed.
({CacheState state, SegmentMeta? baked}) applyBake(
  CacheState state,
  CacheEnv env,
  FrameBake? bake,
) {
  if (bake == null) return (state: state, baked: null);
  final meta = _metaFor(bake.plan, state, env, bake.output);
  return (
    state: state.withSegments([
      ...state.segments.sublist(0, bake.plan.from),
      meta,
      ...state.segments.sublist(bake.plan.to + 1),
    ]),
    baked: meta,
  );
}

/// One blit with all geometry resolved (clip/drawImageRect operands), in
/// logical px: clip to [clipL]..[clipR] horizontally and [clipB]..[clipT]
/// vertically, then draw the source content rect (0,0 to [sw],[sh] physical
/// px) into the [dx]/[dy]/[dw]/[dh] destination.
///
/// Why the destination is an affine: texture x-px u covers sample
/// start + u*(end-start)/contentW, which lands today at
/// (sample - viewStart) * pps -- affine -- so one drawImageRect repositions
/// the content exactly. Vertically, content rows [0, gh] covered values
/// [yMax, yMin] at bake, and valueToY is affine in (yMin, yMax), so a y
/// scale+offset corrects for range AND plot-height changes since the bake.
/// Per-channel offsets (tares) are NOT corrected: one segment composites
/// every channel, so no single affine can hold per-channel shifts -- tares
/// ride the destructive key instead.
typedef BlitRect = ({
  SegmentMeta seg,
  double clipL,
  double clipR,
  double clipB,
  double clipT,
  double dx,
  double dy,
  double dw,
  double dh,
  double sw,
  double sh,
});

/// One uncovered visible range to vector-render, with its placement and clip
/// fully resolved: clip to [clipL]..[clipR] horizontally and [clipB]..[clipT]
/// vertically, render samples [start, end) into [texW] logical px after a
/// translate([x], 0). A raster texture has a width; a gap render does not, so
/// the width the renderer is told to use is a decision like any other and is
/// resolved here rather than derived again in the shell.
typedef GapRect = ({
  int start,
  int end,
  double x,
  double w,
  int texW,
  double clipL,
  double clipR,
  double clipB,
  double clipT,
});

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
    // has at most one blit; the clip is just the view bounds, plus the
    // segment's own vPad band (its padding covers that much overshoot).
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
      clipB: -s.vPad,
      clipT: c.gh + s.vPad,
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
    // The floored coverage start can put a gap's left edge up to one
    // sample-pixel left of the plot area; the translate keeps the content
    // mapping exact, so the CLIPS are what get clamped (a gap is drawn
    // straight to the frame canvas, so its texture width only sets the
    // renderer's mapping).
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
        texW: math.max(1, ((ge - gs) * env.pps).ceil()),
        clipL: math.max((gs - c.viewStart) * env.pps, 0.0),
        clipR: math.min((ge - c.viewStart) * env.pps, c.gw),
        clipB: -c.vPad,
        clipT: c.gh + c.vPad,
      ),
  ];
  return (blits: blits, gaps: gaps);
}

/// The segment-list invariant in executable form: ordered by
/// [SegmentMeta.start], non-empty ranges, no overlaps (gaps are fine).
/// Every transition preserves it; asserts and invariant-testing harnesses
/// call it on states and let it name the violation.
///
/// It cannot see the bake horizon: the horizon is a per-frame input, not a
/// state field, and a segment is allowed to KEEP a range past a horizon that
/// later receded under it (its pixels are already rendered). What the horizon
/// forbids is a bake past it, asserted where bakes are chosen ([planBakes]).
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
