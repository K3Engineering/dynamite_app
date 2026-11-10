import 'dart:math' as math;

// Decisions for the tiled graph cache. The raster shell owns ui.Image,
// canvas calls and bake scheduling; this file imports only dart:math.
//
// [stepCache] performs one complete pure frame transition. Its frame contains
// the blits/gaps to draw and, when needed, one bake for the shell to rasterize
// before drawing them. A bake's logical width is derived from its range and
// bake-time pps, so the renderer has no measurement to report back.

bool _keyEq(List<Object?> a, List<Object?> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Target on-screen width (logical px) of one baked tile texture.
const double kTileTargetPx = 200;

/// Maximum horizontal or vertical resampling drift before a visible tile
/// is refreshed. 0.08 is an educated guess, not a measured quality threshold.
const double kMaxTileDrift = 0.08;

/// Nominal baked line height used by the vertical-smear suppression check.
const double kBakedLinePx = 2.0;

/// Maximum plot-height fraction a vertically stretched baked line may occupy.
const double kMaxBlitLineFraction = 0.25;

/// Narrower uncovered ranges are vector-drawn until they grow or merge.
const double kTileGapBakePx = 40;

/// Cached tiles beyond this many target-widths outside the view are evicted.
const int kTileEvictionMargin = 8;

/// Everything about one cached tile except its shell-owned ui.Image.
final class TileMeta {
  final int textureId;

  /// Absolute sample range, half-open.
  final int start;
  final int end;

  /// Logical px per sample when the texture was baked.
  final double pps;

  /// Logical content width, excluding horizontal image padding.
  double get contentW => (end - start) * pps;

  /// Y-mapping at bake: content rows [0, gh) covered values [yMax, yMin].
  final double yMin;
  final double yMax;
  final double gh;
  final double dpr;

  final int generation;
  final List<Object?> suppressKey;
  final List<Object?> ghostKey;

  final double hPad;
  final double vPad;

  new({
    required this.textureId,
    required this.start,
    required this.end,
    required this.pps,
    required this.yMin,
    required this.yMax,
    required this.gh,
    required this.dpr,
    required this.generation,
    required this.suppressKey,
    required this.ghostKey,
    required this.hPad,
    required this.vPad,
  });
}

/// One frame's geometry, data/config identity, sample domain and texture pads.
typedef CacheConfig = ({
  int generation,
  List<Object?> suppressKey,
  List<Object?> ghostKey,
  double gw,
  double gh,
  double dpr,
  double viewStart,
  double viewSpan,
  double yMin,
  double yMax,
  int totalSamples,
  int bakeHorizon,
  double hPad,
  double vPad,
});

/// Immutable cache state. Texture IDs never repeat within a shell lifetime.
final class CacheState {
  /// Ordered, nonempty, nonoverlapping sample ranges.
  final List<TileMeta> tiles;
  final int nextTextureId;

  const new({this.tiles = const [], this.nextTextureId = 0});

  CacheState withTiles(List<TileMeta> tiles) =>
      CacheState(tiles: tiles, nextTextureId: nextTextureId);
}

typedef CacheEnv = ({
  CacheConfig config,
  double pps,
  int covStart,
  int covEnd,
  int targetSpan,
});

CacheEnv cacheEnvFor(CacheConfig c) {
  final double viewEnd = c.viewStart + c.viewSpan;
  final double pps = c.gw / c.viewSpan;
  // Samples exist only at non-negative indices, so young live views with
  // viewStart < 0 never spend textures on negative-sample empty space.
  final int covStart = math.max(0, c.viewStart.floor());
  final int covEnd = math.max(covStart, viewEnd.ceil());
  return (
    config: c,
    pps: pps,
    covStart: covStart,
    covEnd: covEnd,
    targetSpan: math.max(1, (kTileTargetPx / pps).round()),
  );
}

typedef BakePlan = ({int from, int to, int start, int end});

typedef BlitRect = ({
  TileMeta tile,
  double clipL,
  double clipT,
  double clipR,
  double clipB,
  double dx,
  double dy,
  double dw,
  double dh,
  double sw,
  double sh,
});

typedef GapRect = ({
  int start,
  int end,
  double x,
  double clipL,
  double clipT,
  double clipR,
  double clipB,
});

typedef CacheFrame = ({
  BakePlan? bake,
  List<BlitRect> blits,
  List<GapRect> gaps,
});

typedef CacheStep = ({CacheState state, CacheFrame frame});

bool _configStale(TileMeta s, CacheConfig c) =>
    !_keyEq(s.suppressKey, c.suppressKey) ||
    !_keyEq(s.ghostKey, c.ghostKey) ||
    (s.gh - c.gh).abs() > 0.1 ||
    s.dpr != c.dpr;

double _blitYScale(TileMeta s, CacheConfig c) =>
    (s.yMax - s.yMin) / (c.yMax - c.yMin) * (c.gh / s.gh);

bool _driftStale(TileMeta s, CacheEnv env) {
  final double xScale = env.pps / s.pps;
  final double yScale = (s.yMax - s.yMin) / (env.config.yMax - env.config.yMin);
  return math.max((1 - xScale).abs(), (1 - yScale).abs()) > kMaxTileDrift;
}

bool _contentStale(TileMeta s, CacheEnv env) =>
    _configStale(s, env.config) || _driftStale(s, env);

/// Whether a tile remains useful under this frame's config and window.
/// Off-view config-stale tiles are dropped wherever they went off-view; pure
/// drift-stale tiles remain available for pan-back.
bool _keepTile(TileMeta s, CacheEnv env) {
  final c = env.config;
  if (s.generation != c.generation) return false;
  final margin = kTileEvictionMargin * env.targetSpan;
  if (s.end < env.covStart - margin || s.start > env.covEnd + margin) {
    return false;
  }
  final inView = s.end > env.covStart && s.start < env.covEnd;
  if (!inView) return !_configStale(s, c);
  final hasRefreshable =
      math.min(s.end, math.min(c.bakeHorizon, env.covEnd)) >
      math.max(s.start, env.covStart);
  return hasRefreshable || !_contentStale(s, env);
}

CacheState _prepare(CacheState state, CacheEnv env) {
  if (state.tiles.every((s) => _keepTile(s, env))) return state;
  return state.withTiles([
    for (final s in state.tiles)
      if (_keepTile(s, env)) s,
  ]);
}

/// Uncovered sub-ranges of the visible, written domain.
List<(int, int)> _gaps(
  List<TileMeta> tiles,
  int covStart,
  int covEnd,
  int domainEnd,
) {
  final end = math.min(covEnd, domainEnd);
  final gaps = <(int, int)>[];
  int covered = covStart;
  for (final s in tiles) {
    if (covered >= end) break;
    if (s.start > covered) gaps.add((covered, math.min(s.start, end)));
    covered = math.max(covered, s.end);
  }
  if (covered < end) gaps.add((covered, end));
  return gaps;
}

/// Fill the widest uncovered gap, right aligned. Narrow boxed-in gaps absorb
/// an abutting neighbor immediately when the merged tile stays within 1.5
/// targets, avoiding a narrow bake followed by a merge bake.
BakePlan? _bakeWidestGap(List<TileMeta> tiles, CacheEnv env) {
  (int, int)? bakeGap;
  double widestPx = kTileGapBakePx;
  for (final g in _gaps(
    tiles,
    env.covStart,
    env.covEnd,
    env.config.bakeHorizon,
  )) {
    final double w = (g.$2 - g.$1) * env.pps;
    if (w > widestPx) {
      widestPx = w;
      bakeGap = g;
    }
  }
  if (bakeGap == null) return null;

  int end = bakeGap.$2;
  int start = math.max(bakeGap.$1, end - env.targetSpan);
  if ((start - bakeGap.$1) * env.pps <= kTileGapBakePx) {
    start = bakeGap.$1;
  }
  assert(end > start);

  int at = 0;
  while (at < tiles.length && tiles[at].start < start) {
    at++;
  }
  int from = at;
  int to = at - 1;
  while (from > 0 &&
      tiles[from - 1].end == start &&
      tiles[from - 1].end > env.covStart &&
      (end - tiles[from - 1].start) * env.pps <= kTileTargetPx) {
    from--;
    start = tiles[from].start;
  }

  if ((end - start) * env.pps < kTileTargetPx / 2) {
    while (from > 0 &&
        tiles[from - 1].end == start &&
        tiles[from - 1].end > env.covStart &&
        (end - tiles[from - 1].start) * env.pps <= 1.5 * kTileTargetPx) {
      from--;
      start = tiles[from].start;
    }
    final domainEnd = math.min(env.covEnd, env.config.bakeHorizon);
    if (at < tiles.length &&
        tiles[at].start == end &&
        tiles[at].end <= domainEnd &&
        (tiles[at].end - start) * env.pps <= 1.5 * kTileTargetPx) {
      end = tiles[at].end;
      to = at;
    }
  }

  start = math.max(start, env.covStart);
  return (from: from, to: to, start: start, end: end);
}

BakePlan? _refreshStaleTile(List<TileMeta> tiles, CacheEnv env) {
  for (int i = tiles.length - 1; i >= 0; i--) {
    final s = tiles[i];
    if (s.end <= env.covStart || s.start >= env.covEnd) continue;
    if (!_contentStale(s, env)) continue;
    final p = _planRefresh(tiles, i, env);
    if (p != null) return p;
  }
  return null;
}

/// Refresh geometry is shared by config and drift staleness. Every resulting
/// bake is content-fresh under the current env, so no identity-plan exception
/// or size-only staleness predicate is needed.
BakePlan? _planRefresh(List<TileMeta> tiles, int i, CacheEnv env) {
  final int bakeable = env.config.bakeHorizon;
  final s = tiles[i];
  final int end = math.min(s.end, math.min(bakeable, env.covEnd));
  if (end <= math.max(s.start, env.covStart)) return null;
  if ((end - s.start) * env.pps > 1.8 * kTileTargetPx &&
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
      tiles[from - 1].end == start &&
      tiles[from - 1].end > env.covStart &&
      (end - tiles[from - 1].start) * env.pps <= 1.5 * kTileTargetPx) {
    from--;
    start = tiles[from].start;
  }
  int mergedEnd = end;
  int to = i;
  if ((mergedEnd - start) * env.pps < kTileTargetPx / 2) {
    final int domainEnd = math.min(env.covEnd, bakeable);
    final int uncoveredLimit = math.min(
      to + 1 < tiles.length ? tiles[to + 1].start : domainEnd,
      domainEnd,
    );
    mergedEnd = math.max(
      mergedEnd,
      math.min(start + env.targetSpan, uncoveredLimit),
    );
    if ((mergedEnd - start) * env.pps < kTileTargetPx / 2 &&
        to + 1 < tiles.length &&
        tiles[to + 1].start == mergedEnd &&
        tiles[to + 1].end <= domainEnd &&
        (tiles[to + 1].end - start) * env.pps <= 1.5 * kTileTargetPx) {
      to++;
      mergedEnd = tiles[to].end;
    }
  }
  return _clampPlan((from: from, to: to, start: start, end: mergedEnd), env);
}

BakePlan _clampPlan(BakePlan p, CacheEnv env) => (
  from: p.from,
  to: p.to,
  start: math.max(p.start, env.covStart),
  end: math.min(p.end, math.min(env.covEnd, env.config.bakeHorizon)),
);

TileMeta _metaFor(BakePlan plan, int textureId, CacheEnv env) {
  final c = env.config;
  return TileMeta(
    textureId: textureId,
    start: plan.start,
    end: plan.end,
    pps: env.pps,
    yMin: c.yMin,
    yMax: c.yMax,
    gh: c.gh,
    dpr: c.dpr,
    generation: c.generation,
    suppressKey: List.of(c.suppressKey),
    ghostKey: List.of(c.ghostKey),
    hPad: c.hPad,
    vPad: c.vPad,
  );
}

bool _isBlittable(TileMeta s, CacheConfig c) {
  if (!_keyEq(s.suppressKey, c.suppressKey)) return false;
  return _blitYScale(s, c) * kBakedLinePx <= c.gh * kMaxBlitLineFraction;
}

GapRect _gapRect(int start, int end, CacheConfig c, double pps) {
  final double x = (start - c.viewStart) * pps;
  final double w = (end - start) * pps;
  return (
    start: start,
    end: end,
    x: x,
    clipL: math.max(x, 0.0),
    clipT: -c.vPad,
    clipR: math.min(x + w, c.gw),
    clipB: c.gh + c.vPad,
  );
}

List<BlitRect> _blits(CacheState state, CacheEnv env) {
  final c = env.config;
  final blits = <BlitRect>[];
  for (final s in state.tiles) {
    if (!_isBlittable(s, c)) continue;
    final double x1 = (s.start - c.viewStart) * env.pps;
    final double x2 = (s.end - c.viewStart) * env.pps;
    final double clipL = math.max(x1, 0.0);
    final double clipR = math.min(x2, c.gw);
    if (clipR <= clipL) continue;

    final double xs = env.pps / s.pps;
    final double ys = _blitYScale(s, c);
    final double yTop = c.gh * (1 - (s.yMax - c.yMin) / (c.yMax - c.yMin));
    blits.add((
      tile: s,
      clipL: clipL,
      clipT: -s.vPad,
      clipR: clipR,
      clipB: c.gh + s.vPad,
      dx: x1 - s.hPad * xs,
      dy: yTop - s.vPad * ys,
      dw: (s.contentW + 2 * s.hPad) * xs,
      dh: (s.gh + 2 * s.vPad) * ys,
      sw: (s.contentW + 2 * s.hPad) * s.dpr,
      sh: (s.gh + 2 * s.vPad) * s.dpr,
    ));
  }
  return blits;
}

/// Advance the cache through one frame and resolve everything the shell must
/// rasterize. The optional [CacheFrame.bake] refers to the tile inserted at
/// its `from` index in the returned state.
CacheStep stepCache(CacheState state, CacheConfig config) {
  final env = cacheEnvFor(config);
  final prepared = _prepare(state, env);
  final plan =
      _bakeWidestGap(prepared.tiles, env) ??
      _refreshStaleTile(prepared.tiles, env);
  if (plan != null) {
    assert(
      plan.start >= env.covStart &&
          plan.end <= env.covEnd &&
          plan.end <= env.config.bakeHorizon,
      'bake [${plan.start}, ${plan.end}) outside fold window '
      '[${env.covStart}, ${env.covEnd}) or past bake horizon '
      '${env.config.bakeHorizon}',
    );
  }

  final next = plan == null
      ? prepared
      : CacheState(
          nextTextureId: prepared.nextTextureId + 1,
          tiles: [
            ...prepared.tiles.sublist(0, plan.from),
            _metaFor(plan, prepared.nextTextureId, env),
            ...prepared.tiles.sublist(plan.to + 1),
          ],
        );
  return (
    state: next,
    frame: (
      bake: plan,
      blits: _blits(next, env),
      gaps: [
        for (final (gs, ge) in _gaps(
          next.tiles,
          env.covStart,
          env.covEnd,
          config.totalSamples,
        ))
          _gapRect(gs, ge, config, env.pps),
      ],
    ),
  );
}

List<String> invariantViolations(CacheState state) {
  final violations = <String>[];
  final segs = state.tiles;
  for (int k = 0; k < segs.length; k++) {
    if (segs[k].end <= segs[k].start) {
      violations.add(
        'tile $k has empty range [${segs[k].start}, ${segs[k].end})',
      );
    }
    if (k > 0 && segs[k - 1].end > segs[k].start) {
      violations.add(
        'tiles ${k - 1} and $k overlap: '
        '[${segs[k - 1].start}, ${segs[k - 1].end}) vs '
        '[${segs[k].start}, ${segs[k].end})',
      );
    }
  }
  return violations;
}
