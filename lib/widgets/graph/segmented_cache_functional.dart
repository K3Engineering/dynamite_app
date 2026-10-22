import 'dart:math' as math;

// Segmented graph cache: the decisions. The raster shell
// (segmented_cache.dart) owns ui.Image, canvas calls and bake scheduling and
// imports this file; nothing here may import the shell, dart:ui, a package or a
// clock. Nothing enforces that (a `dart:ui` import analyzes fine), so it is
// review's job.
//
// One frame is four transitions around one impure measurement:
//
//   (state, env) --prepareFrame--> state'
//   state'       --planBakes-----> at most one plan, or null for a quiet frame
//   [shell rasterizes the plan, reading the render closure]
//   (state', bake) --applyBake--> state'' + the meta the bake produced
//   state''      --rasterPlan----> blit rects + gap rects to draw
//
// State is immutable: each transition returns a new [CacheState] sharing the
// unchanged [SegmentMeta] instances. [SegmentMeta.textureId] names the shell's
// texture; the shell frees whatever the segment list no longer names.
//
// The staleness model and both coverage invariants (bake horizon, fold window)
// are in the shell file's header. [planBakes] asserts the coverage invariants
// for every bake it returns; [invariantViolations] states the segment-list
// invariant in executable form for asserts and tests.

/// [List] equality without the flutter/foundation import, so this file stays
/// pure-Dart and testable under plain `dart test`.
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

/// Nominal baked line height (stroke + AA, logical px): the constant term the
/// corrective vertical blit stretch multiplies (see [_isBlittable]).
const double kBakedLinePx = 2.0;

/// Max fraction of the plot height a vertically stretched baked line may
/// occupy before the segment's blit is suppressed (see [_isBlittable]): past
/// it, the stretch -- e.g. a channel switch-off collapsing the Y-range onto a
/// quiet channel -- reads as a screen-filling smear.
const double kMaxBlitLineFraction = 0.25;

/// Min on-screen width (logical px) of an uncovered range before a bake is
/// spent on it. Narrower gaps -- e.g. the live-edge sliver -- are drawn as
/// vectors every frame until they outgrow this.
const double kSegmentGapBakePx = 40;

/// Cached segments more than this many target-widths outside the view are
/// evicted; a segment is kSegmentTargetPx * dpr * plotHeight * dpr * 4 bytes
/// (a few MB on a tall graph at dpr 2), so the cache cannot be unbounded.
const int kSegmentEvictionMargin = 8;

/// Everything about one cached segment except its texture, which the shell
/// owns as textureId -> ui.Image.
final class SegmentMeta {
  /// Names the shell's texture. Assigned by the shell as a serial, never
  /// derived from the meta's content: two metas with the same range can own
  /// different textures.
  final int textureId;

  /// Sample range the texture covers (absolute indices, half-open).
  final int start;
  final int end;

  /// Logical px the content occupies in the texture; the blit's x-scale
  /// reference.
  final double contentW;

  /// Y-mapping at bake: content rows [0, gh) covered values [yMax, yMin].
  final double yMin;
  final double yMax;

  /// Plot height and pixel ratio at bake; the blit corrects for both, so a
  /// change is resampling drift rather than invalidation.
  final double gh;
  final double dpr;

  /// Config keys at bake. A [destructiveKey] mismatch must never blit; a
  /// [remapKey] mismatch leaves the content approximately right (a ghost) and
  /// blittable until the sweep replaces it.
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
/// bake horizon, and texture padding.
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

/// The decision-relevant state of the whole cache: the segment metas and the
/// config stamps they are compared against.
final class CacheState {
  /// Metas ordered by [SegmentMeta.start], never overlapping (see
  /// [invariantViolations]). Ranges between segments are gaps: vector-drawn or
  /// left blank until a bake covers them.
  final List<SegmentMeta> segments;

  /// The cache's current stamps; metas carry their own. [generation] identifies
  /// the data stream itself; a change clears everything.
  final int generation;
  final double gh;
  final double dpr;
  final List<Object?> destructiveKey;
  final List<Object?> remapKey;

  const CacheState._({
    required this.segments,
    required this.generation,
    required this.gh,
    required this.dpr,
    required this.destructiveKey,
    required this.remapKey,
  });

  /// A cache that has never seen a frame: no segments, stamped from [c].
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

  /// Adopt [c]'s config as the current stamps. The lists are copied: callers
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

/// The frame config plus the quantities derived from it once
/// ([cacheEnvFor]), so every decision reads the same derived values.
typedef CacheEnv = ({
  CacheConfig config,
  double pps, // logical px per sample
  int covStart,
  int covEnd,
  int targetSpan,
});

CacheEnv cacheEnvFor(CacheConfig c) {
  final double viewEnd = c.viewStart + c.viewSpan;
  final double pps = c.gw / c.viewSpan;
  return (
    config: c,
    pps: pps,
    // Coverage bookkeeping is integer: bakes and gap ranges are sample-aligned
    // (block anchoring). The fractional scroll offset only shifts blit
    // placement (see [rasterPlan]).
    covStart: c.viewStart.floor(),
    covEnd: viewEnd.ceil(),
    targetSpan: math.max(1, (kSegmentTargetPx / pps).round()),
  );
}

/// Whether the given config stamps differ from [state]'s. Used against the
/// frame config (a bump re-stamps, see [prepareFrame]) and against a segment's
/// bake stamps (a mismatch makes it stale).
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

/// Transition 1: apply generation/config changes and evict segments the frame
/// can no longer use. Segments it dropped are simply absent from the result,
/// which is what the shell frees textures from.
///
/// Two kinds of drop: segments far outside the view (beyond
/// [kSegmentEvictionMargin] target widths), so the cache stays bounded; and
/// segments [_isRetired] names -- stale content with no sample left inside the
/// window at or below the horizon, which the sweep could only drop anyway.
///
/// [state] is null on the first frame: a fresh cache adopts the config's stamps
/// with no segments.
CacheState prepareFrame(CacheState? state, CacheEnv env) {
  final config = env.config;
  if (state == null) return CacheState.fresh(config);
  final result = _restamp(state, env);
  final int margin = kSegmentEvictionMargin * env.targetSpan;
  // Scan before allocating: the quiet frame (nothing dropped) is the common one
  // and must hand back the same list, which is also what tells the shell no
  // texture can have been orphaned.
  if (!result.segments.any(
    (s) =>
        s.end < env.covStart - margin ||
        s.start > env.covEnd + margin ||
        _isRetired(s, result, env),
  )) {
    return result;
  }
  return result.withSegments([
    for (final s in result.segments)
      if (s.end >= env.covStart - margin &&
          s.start <= env.covEnd + margin &&
          !_isRetired(s, result, env))
        s,
  ]);
}

/// [state] under the frame's stamps: empty on a generation change, restricted
/// to the visible segments on a config bump, unchanged otherwise.
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
/// purely geometric: a segment counts as covered even when it may not blit.
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
/// [planBakes] returns with a bake of samples [start, end).
typedef BakePlan = ({int from, int to, int start, int end});

/// Transition 2: choose this frame's (re)bake -- priority:
///   1. the widest visible gap past [kSegmentGapBakePx];
///   2. the rightmost visible stale segment (see [_stalePlan]).
///
/// Null for a quiet frame. Bakes are rationed to one per frame to keep a steady
/// frame rate (see the shell file header).
///
/// The fold-window and bake-horizon invariants are asserted here: every bake
/// decision passes through here, so they hold for every (re)bake path.
BakePlan? planBakes(CacheState state, CacheEnv env) {
  final plan =
      _bakeWidestGap(state.segments, env) ??
      _refreshStaleSegment(state.segments, state, env);
  if (plan == null) return null;
  assert(
    plan.start >= env.covStart &&
        plan.end <= env.covEnd &&
        plan.end <= env.config.bakeableSamples,
    'bake [${plan.start}, ${plan.end}) outside fold window '
    '[${env.covStart}, ${env.covEnd}) or past the bake horizon '
    '${env.config.bakeableSamples}',
  );
  return plan;
}

/// Whether the horizon has retired [s]: its content is config- or drift-stale,
/// and no sample of it is left inside the window at or below the horizon, so
/// the sweep could only drop it. A segment baked under a further-out horizon
/// still covers samples past it and keeps blitting; only one left with no
/// refreshable range goes.
///
/// The window/horizon test comes first because it is a few integer comparisons
/// and it is the common answer; staleness then only runs for a segment that has
/// nothing left.
///
/// Size-stale segments are excluded by kind: retiring one would drop a tile
/// whose only problem is width, and [_stalePlan]'s identity tie-break already
/// keeps it from re-baking forever.
bool _isRetired(SegmentMeta s, CacheState state, CacheEnv env) {
  if (s.end <= env.covStart || s.start >= env.covEnd) return false;
  final int refreshableEnd = math.min(
    s.end,
    math.min(env.config.bakeableSamples, env.covEnd),
  );
  if (refreshableEnd > math.max(s.start, env.covStart)) return false;
  return _contentStale(s, state, env);
}

/// The meta a [bake] produced, given the impure measurement the shell made for
/// it.
SegmentMeta _metaFor(FrameBake bake, CacheState state, CacheEnv env) {
  final plan = bake.plan;
  final c = env.config;
  return SegmentMeta(
    textureId: bake.textureId,
    start: plan.start,
    end: plan.end,
    contentW: math.max(bake.contentW, 0.001),
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

/// Priority 1: bake the widest uncovered gap past the threshold, right aligned.
/// In a moving window (live follow, pans) the left side exits first, so left
/// alignment spends every bake at the exiting edge. Gaps up to one target span
/// get the same range either way; only over-wide gaps differ, and rightmost-first
/// matches the config sweep.
///
/// A remainder left of the bake too narrow to ever re-cross the threshold is
/// swallowed into the bake: one abutting existing coverage would vector-draw
/// forever. Left neighbors are absorbed while the merged bake stays within one
/// target width, so the live-edge segment grows in place instead of accumulating
/// sliver-wide strips.
///
/// The plan's [BakePlan.from]/[BakePlan.to] mark the absorbed segments to
/// replace; from == at is a plain insert (to == at - 1).
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
  int from = at;
  while (from > 0 &&
      (end - segments[from - 1].start) * env.pps <= kSegmentTargetPx) {
    from--;
  }
  if (from < at) start = segments[from].start;
  // An absorbed neighbor may straddle the left view edge; the fold-window
  // invariant caps the bake at the window, dropping the neighbor's out-of-fold
  // fringe to an out-of-view gap.
  start = math.max(start, env.covStart);

  return (from: from, to: at - 1, start: start, end: end);
}

/// Priority 2: re-bake the rightmost visible stale segment (see [_stalePlan]).
/// Skips segments out of view and segments with nothing to re-bake, so a frame
/// with nothing stale returns null.
BakePlan? _refreshStaleSegment(
  List<SegmentMeta> segments,
  CacheState state,
  CacheEnv env,
) {
  for (int i = segments.length - 1; i >= 0; i--) {
    final s = segments[i];
    if (s.end <= env.covStart || s.start >= env.covEnd) continue;
    final p = _stalePlan(segments, state, i, env);
    if (p == null) continue;
    return p;
  }
  return null;
}

/// Whether [s] may blit under the current Y-mapping: the destructive key must
/// match, and the corrective vertical stretch must keep the baked line
/// ([kBakedLinePx] at bake) within [kMaxBlitLineFraction] of the plot height.
/// One-sided: shrinking only sharpens, but a large stretch smears the segment's
/// line across the screen. A suppressed segment is kept, not disposed: a
/// Y-range snap-back makes it blittable again.
bool _isBlittable(SegmentMeta s, CacheState state, CacheEnv env) {
  if (!_keyEq(s.destructiveKey, state.destructiveKey)) return false;
  return _blitYScale(s, env.config) * kBakedLinePx <=
      env.config.gh * kMaxBlitLineFraction;
}

/// The corrective vertical scale a blit of [s] applies: baked value-range drift
/// times the plot-height ratio since the bake.
double _blitYScale(SegmentMeta s, CacheConfig c) =>
    (s.yMax - s.yMin) / (c.yMax - c.yMin) * (c.gh / s.gh);

/// Whether [s]'s pixels are wrong in kind or place -- baked under outdated keys,
/// gh or dpr, or drifted past [kMaxSegmentDrift] on either axis. Only content
/// staleness can make a segment unrefreshable ([_isRetired]); [_sizeStale] is a
/// width policy and never retires.
bool _contentStale(SegmentMeta s, CacheState state, CacheEnv env) =>
    _configDiffers(s.destructiveKey, s.remapKey, s.gh, s.dpr, state) ||
    _driftStale(s, env);

/// Whether [s] has drifted past [kMaxSegmentDrift] on either axis: the
/// resampling error a blit of it would bake in.
bool _driftStale(SegmentMeta s, CacheEnv env) {
  final double w = (s.end - s.start) * env.pps;
  final double xScale = w / s.contentW;
  final double yScale = (s.yMax - s.yMin) / (env.config.yMax - env.config.yMin);
  return math.max((1 - xScale).abs(), (1 - yScale).abs()) > kMaxSegmentDrift;
}

/// Whether [s] is past two targets on screen or under half a target: the width
/// policy behind split, merge and grow in [_planRefresh].
bool _sizeStale(SegmentMeta s, CacheEnv env) {
  final double w = (s.end - s.start) * env.pps;
  return w > 2 * kSegmentTargetPx || w < kSegmentTargetPx / 2;
}

/// The refresh plan for [i] if it needs one, else null. Config and drift
/// staleness take whatever plan [_planRefresh] computes, including an absorbed
/// left neighbor: two tiles that both need re-baking are cheaper merged into one
/// bake than refreshed in two frames.
///
/// A size outlier is only worth a bake if the bake would CHANGE its geometry.
/// One whose refresh can only reproduce its own range is left alone: re-baking
/// identical pixels every frame is a bake-pump-fed busy loop.
BakePlan? _stalePlan(
  List<SegmentMeta> segments,
  CacheState state,
  int i,
  CacheEnv env,
) {
  final s = segments[i];
  final bool contentStale = _contentStale(s, state, env);
  if (!contentStale && !_sizeStale(s, env)) return null;
  final p = _planRefresh(segments, i, env);
  if (p == null || contentStale) return p;
  // Compare against the identity plan clamped by the same helper
  // [_planRefresh] uses, or a straddling size outlier would read its own
  // clamped shape as a geometry change and re-bake every frame.
  final identity = _clampPlan((
    from: i,
    to: i,
    start: s.start,
    end: s.end,
  ), env);
  return p != identity ? p : null;
}

/// Where a refresh of [i] would bake and which segments it would replace,
/// independent of why; null when no sample of [s] is left inside the window at
/// or below the horizon (nothing to bake). Disjointness (see
/// [invariantViolations]) makes this a partition operation rather than range
/// arithmetic: the refresh never crosses the next segment's start, and swallows
/// neighbors only whole.
///
/// Past two targets on screen it splits to the RIGHTMOST target span, so the
/// left remainder pairs with [_bakeWidestGap]'s right-aligned fill and the hole
/// refills marching left instead of stranding a sliver between two tiles. The
/// `end - targetSpan > s.start` clause is the progress guard: at pps over
/// ~200 px/sample the span hits its 1-sample floor and cannot shrink the
/// segment.
///
/// Otherwise it swallows abutting LEFT neighbors while the merged width stays
/// within 1.5 targets -- left, because the sweep runs rightmost-first and those
/// are the still-stale ones. 1.5 rather than the 2-target split cap leaves
/// headroom, or the next mild zoom-in splits the merged tile again. Under half a
/// target it grows the end into UNCOVERED room only (capped by the next
/// segment's start and the horizon), and if still narrow with an abutting right
/// neighbor, swallows that neighbor under the same 1.5 cap.
BakePlan? _planRefresh(List<SegmentMeta> segments, int i, CacheEnv env) {
  final int bakeable = env.config.bakeableSamples;
  final s = segments[i];
  // Retract to the fold window as well as the horizon: [s] may straddle the
  // right view edge from window motion.
  final int end = math.min(s.end, math.min(bakeable, env.covEnd));
  if (end <= math.max(s.start, env.covStart)) return null;
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

/// Confine a refresh plan's bake range to the fold window and the bake horizon,
/// the two coverage invariants in the shell file header. The only place those
/// clamps are written: a swallowed LEFT neighbor may straddle the left view
/// edge, and a swallowed RIGHT neighbor (or a grown end) may reach the right
/// edge -- or past a RECEDED horizon, which neighbors are never trimmed to.
/// Out-of-window fringes drop to gaps.
BakePlan _clampPlan(BakePlan p, CacheEnv env) => (
  from: p.from,
  to: p.to,
  start: math.max(p.start, env.covStart),
  end: math.min(p.end, math.min(env.covEnd, env.config.bakeableSamples)),
);

/// One bake the shell measured: the plan the core chose and what the render
/// reported for it, kept together so a measurement cannot be attributed to a
/// plan that did not produce it. [textureId] names the texture the shell filed;
/// the core never sees the texture and never predicts [contentW] ahead of the
/// render.
typedef FrameBake = ({BakePlan plan, double contentW, int textureId});

/// Transition 3: commit the frame's bake. [state] is what [prepareFrame]
/// returned, [bake] is what the shell measured for [planBakes]'s plan (null for
/// a quiet frame, which commits nothing).
CacheState applyBake(CacheState state, CacheEnv env, FrameBake? bake) {
  if (bake == null) return state;
  final plan = bake.plan;
  return state.withSegments([
    ...state.segments.sublist(0, plan.from),
    _metaFor(bake, state, env),
    ...state.segments.sublist(plan.to + 1),
  ]);
}

/// One blit with its geometry resolved (the drawImageRect operands), in logical
/// px: clip to [clipL]..[clipR] horizontally and [clipB]..[clipT] vertically,
/// then draw the source content rect (0,0 to [sw],[sh] physical px) into the
/// [dx]/[dy]/[dw]/[dh] destination.
///
/// The destination is affine because the mappings are: texture x-px u covers
/// sample start + u*(end-start)/contentW, which lands today at
/// (sample - viewStart) * pps, and valueToY is affine in (yMin, yMax). So one
/// drawImageRect repositions the content exactly and a y scale+offset also
/// corrects for range and plot-height changes since the bake.
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
/// resolved: clip to [clipL]..[clipR] horizontally and [clipB]..[clipT]
/// vertically, render samples [start, end) into [texW] logical px after a
/// translate([x], 0). A gap is drawn straight to the frame canvas, so [texW]
/// only sets the renderer's x mapping.
typedef GapRect = ({
  int start,
  int end,
  double x,
  int texW,
  double clipL,
  double clipR,
  double clipB,
  double clipT,
});

GapRect _gapRect(int start, int end, CacheConfig c, double pps) {
  final double x = (start - c.viewStart) * pps;
  final double w = (end - start) * pps;
  return (
    start: start,
    end: end,
    x: x,
    texW: math.max(1, w.ceil()),
    // The floored coverage start can put a gap's left edge up to one
    // sample-pixel left of the plot area; the translate keeps the content
    // mapping exact, so the CLIPS are what get clamped.
    clipL: math.max(x, 0.0),
    clipR: math.min(x + w, c.gw),
    clipB: -c.vPad,
    clipT: c.gh + c.vPad,
  );
}

/// Transition 4: resolve what the frame rasterizes -- one [BlitRect] per
/// visible blittable segment and one [GapRect] per uncovered visible range.
///
/// TODO: one record per blit per frame. A reusable output buffer would remove
/// it, at the price of a mutable out-parameter, so only worth it if a profile
/// says so.
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
    // Segments are disjoint (see [invariantViolations]), so one screen x has at
    // most one blit; the clip is the view bounds plus the segment's own vPad
    // band (its padding covers that much overshoot).
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
      // Source is the CONTENT rect (content + pads), not the image bounds: the
      // dead ceil column would otherwise bake a small scale error into every
      // blit, blurring even identity mappings.
      sw: (s.contentW + 2 * s.hPad) * s.dpr,
      sh: (s.gh + 2 * s.vPad) * s.dpr,
    ));
  }
  return (
    blits: blits,
    gaps: [
      for (final (gs, ge) in _gaps(
        state.segments,
        env.covStart,
        env.covEnd,
        c.totalSamples,
      ))
        _gapRect(gs, ge, c, env.pps),
    ],
  );
}

/// The segment-list invariant in executable form: ordered by
/// [SegmentMeta.start], non-empty ranges, no overlaps (gaps are fine). Every
/// transition preserves it; asserts and invariant-testing harnesses call it and
/// let it name the violation.
///
/// It cannot see the bake horizon: the horizon is a per-frame input, not a state
/// field, and a segment is allowed to KEEP a range past a horizon that later
/// receded under it (its pixels are already rendered). What the horizon forbids
/// is a bake past it, asserted where bakes are chosen ([planBakes]).
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
