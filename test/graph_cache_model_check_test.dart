import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/graph/tile_cache_functional.dart';

// Bounded model checking of the pure cache core: BFS over the states
// REACHABLE from an empty cache under a discretized input universe
// (windows, Y ranges, config churn, generations, bake horizons), verifying
// on every single transition:
//   * the tile-list invariant (invariantViolations);
//   * fold-window / bake-horizon containment of every bake (also asserted
//     inside stepCache; checked here independently);
//   * texture ids stay unique, so the shell's reconcile-by-id frees only
//     textures no tile names;
//   * progress: a frame that bakes must change the canonical state, so a
//     constant input can never re-bake identical pixels forever (the
//     bake-pump busy-loop shape).
//
// The "no cycle of bake-carrying edges" half of quiescence is NOT proven
// here (only its one-frame special case, via progress); longer cycles are
// the sim harness's job (graph_cache_sim_test.dart). What this file gives
// that the sim cannot: the state space is CLOSED under the enumerated
// transitions (the run reports whether closure was reached), so these
// invariants hold for every reachable geometry, not a sampled one.
//
// One tier, tagged 'slow' and run as its own CI job: sized for a per-PR check
// but not for the PR suite's wall time. A 12-sample universe reaches closure at
// ~84k states in ~15 s on this repo; that is a budget to re-measure on planner
// changes, not a constant of nature. Reachable-state count is strongly
// superlinear in the universe size and in the number of STAMP axes (a gh or dpr
// flip alone triples it), so the grid stays small and the churn set covers one
// representative per staleness kind (generation reset, suppress flip, ghost
// flip, y-drift, receded horizon) instead of the product. Boundary-threshold
// nuance (drift just past 8%) belongs to the unit tests and the sim.

/// Deterministic canonical form: equal tile metas hash identically regardless
/// of list or meta identity. Texture IDs are shell identities, not cache shape.
String _canon(CacheState s) {
  final b = StringBuffer();
  for (final m in s.tiles) {
    b.write(
      '${m.start},${m.end},${m.pps},${m.yMin},${m.yMax},'
      '${m.gh},${m.dpr},${m.generation},${m.hPad},${m.vPad},',
    );
    b.writeAll(m.suppressKey.map((k) => 'u$k'));
    b.writeAll(m.ghostKey.map((k) => 'r$k'));
    b.write(';');
  }
  return b.toString();
}

bool _sameKey(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

CacheConfig _config({
  required double viewStart,
  required double viewSpan,
  required double yMax,
  required int totalSamples,
  required int bakeHorizon,
  int generation = 0,
  String destKey = 'u1',
  String ghostKey = 'k1',
  double gh = 100,
  double dpr = 1,
}) => (
  generation: generation,
  suppressKey: [destKey],
  ghostKey: [ghostKey],
  gw: 400,
  gh: gh,
  dpr: dpr,
  viewStart: viewStart,
  viewSpan: viewSpan,
  yMin: 0,
  yMax: yMax,
  totalSamples: totalSamples,
  bakeHorizon: bakeHorizon,
  // Opaque to the planner (carried into metas, never read), so any constant
  // works; the value is irrelevant to what this test checks.
  hPad: 4,
  vPad: 4,
);

void main() {
  test('reachable cache states obey the invariants', () {
    final sw = Stopwatch()..start();
    const universe = 12;
    // Well past closure at this size (FIFO order, so arrival depth is the
    // shortest path); the run asserts closure was actually reached.
    const maxDepth = 64;

    final inputs = <CacheConfig>[];
    // Geometry windows under canonical stamps: bootstrap fills, straddles,
    // evictions, splits (a 12-sample tile in a span-8 window is past two
    // targets), absorbs, at both zoom regimes. Windows may extend past the
    // data edge.
    for (double vs = 0; vs <= universe + 8; vs += 2) {
      for (final span in [8.0, 16.0]) {
        inputs.add(
          _config(
            viewStart: vs,
            viewSpan: span,
            yMax: 100,
            totalSamples: universe,
            bakeHorizon: universe,
          ),
        );
      }
    }
    // Fractional windows (the smooth-scroll lead makes every live frame
    // fractional): floor/ceil off-by-ones in the coverage window shave
    // 1-sample edge slivers, baked at span-8 pps.
    for (final vs in [2.5, 10.3]) {
      for (final span in [8.0, 16.0]) {
        inputs.add(
          _config(
            viewStart: vs,
            viewSpan: span,
            yMax: 100,
            totalSamples: universe,
            bakeHorizon: universe,
          ),
        );
      }
    }
    // On two representative windows, one representative per staleness
    // kind: y-drift (baked under 100, refreshed at 130 -- the 8% boundary
    // is the unit tests' job), a receded bake horizon, generation reset,
    // destructive flip, remap flip. gh/dpr flips are NOT here: each is another
    // STAMP axis and multiplying the reachable space by it took this check
    // from ~25 s to ~60 s, while the unit tests already pin their staleness
    // kind ("a gh change is remap staleness", "a dpr change is ...").
    for (final vs in [0.0, 8.0]) {
      for (final yMax in [100.0, 130.0]) {
        inputs.add(
          _config(
            viewStart: vs,
            viewSpan: 16,
            yMax: yMax,
            totalSamples: universe,
            bakeHorizon: universe,
          ),
        );
      }
      for (final bakeable in [universe, universe * 3 ~/ 4]) {
        inputs.add(
          _config(
            viewStart: vs,
            viewSpan: 16,
            yMax: 100,
            totalSamples: universe,
            bakeHorizon: bakeable,
          ),
        );
      }
      inputs.addAll([
        _config(
          viewStart: vs,
          viewSpan: 16,
          yMax: 100,
          totalSamples: universe,
          bakeHorizon: universe,
          generation: 1,
        ),
        _config(
          viewStart: vs,
          viewSpan: 16,
          yMax: 100,
          totalSamples: universe,
          bakeHorizon: universe,
          destKey: 'u2',
        ),
        _config(
          viewStart: vs,
          viewSpan: 16,
          yMax: 100,
          totalSamples: universe,
          bakeHorizon: universe,
          ghostKey: 'k2',
        ),
      ]);
    }

    void check(bool ok, String reason) {
      if (!ok) throw StateError('model check violation: $reason');
    }

    // Texture IDs are shell identities and deliberately excluded from _canon.
    final seen = <String>{_canon(const CacheState())};
    final frontier = Queue<(int, CacheState)>()..add((0, const CacheState()));
    var edges = 0, bakeEdges = 0, capped = false;

    while (frontier.isNotEmpty) {
      final (depth, s) = frontier.removeFirst();
      if (depth >= maxDepth) {
        capped = true;
        continue;
      }
      final sCanon = _canon(s);
      for (final input in inputs) {
        edges++;
        final env = cacheEnvFor(input);
        final step = stepCache(s, input);
        final plan = step.frame.bake;
        final next = step.state;
        if (plan != null) {
          check(
            plan.start >= env.covStart &&
                plan.end <= env.covEnd &&
                plan.end <= input.bakeHorizon,
            'bake [${plan.start}, ${plan.end}) outside fold window '
            '[${env.covStart}, ${env.covEnd}) or past horizon '
            '${input.bakeHorizon}',
          );
        }
        if (plan != null) {
          bakeEdges++;
          // Progress: a bake frame must move the state, so a constant
          // input cannot re-bake identical pixels next frame.
          check(
            _canon(next) != sCanon,
            'bake under a constant input changed nothing',
          );
          // The bake's meta landed at the plan's insertion point, carrying the
          // id the shell filed its texture under.
          check(
            next.tiles[plan.from].textureId == s.nextTextureId,
            'a committed bake filed no meta',
          );
        }
        final violations = invariantViolations(next);
        check(violations.isEmpty, violations.join('; '));
        // Retirement, stated without the core's own predicate so it is a real
        // net: no tile stepCache hands on may be past the eviction
        // margin, nor content-stale with no sample left inside the window at
        // or below the horizon. The latter is the case that matters: such a
        // tile blits frozen pixels in the horizon zone forever, because the
        // sweep could only drop it, never re-bake it.
        //
        // Kept tiles only. The other direction (a fresh tile must not be
        // retired) is not expressible this way: stepCache also drops
        // off-view tiles on a config bump, so "dropped implies stale" is
        // false by design. tile_cache_retire_test pins that direction.
        bool pastMargin(TileMeta m) =>
            m.end < env.covStart - kTileEvictionMargin * env.targetSpan ||
            m.start > env.covEnd + kTileEvictionMargin * env.targetSpan;
        bool contentStale(TileMeta m) =>
            m.generation != input.generation ||
            !_sameKey(m.suppressKey, input.suppressKey) ||
            !_sameKey(m.ghostKey, input.ghostKey) ||
            (m.gh - input.gh).abs() > 0.1 ||
            m.dpr != input.dpr ||
            math.max(
                  (1 - env.pps / m.pps).abs(),
                  (1 - (m.yMax - m.yMin) / (input.yMax - input.yMin)).abs(),
                ) >
                kMaxTileDrift;
        bool noRefreshableSample(TileMeta m) =>
            math.min(m.end, math.min(input.bakeHorizon, env.covEnd)) <=
            math.max(m.start, env.covStart);
        bool shouldRetire(TileMeta m) =>
            m.end > env.covStart &&
            m.start < env.covEnd &&
            contentStale(m) &&
            noRefreshableSample(m);
        for (final m in next.tiles) {
          check(
            !pastMargin(m) && !shouldRetire(m),
            'stepCache kept [${m.start},${m.end}) '
            '(pastMargin=${pastMargin(m)} shouldRetire=${shouldRetire(m)}) '
            'at win=[${env.covStart},${env.covEnd}) '
            'horizon=${input.bakeHorizon}',
          );
        }
        // Tiles the frame dropped are gone from the state, and every
        // surviving tile's texture id is unique -- the shell reconciles its
        // texture map against exactly this list (see _reconcileTextures), so a
        // survived drop would free a texture still in use.
        final ids = {for (final m in next.tiles) m.textureId};
        check(ids.length == next.tiles.length, 'two tiles share a texture id');
        // Coverage completeness, measured against the window computed
        // from FIRST PRINCIPLES (locals -- a wrong cacheEnvFor derivation
        // is self-consistent and the containment checks above cannot see
        // it; the floor/ceil-swap mutant survives without this): what the
        // frame would draw must cover the whole intended window.
        final wantStart = input.viewStart.floor();
        final wantEnd = math.min(
          (input.viewStart + input.viewSpan).ceil(),
          input.totalSamples,
        );
        final raster = step.frame;
        final intervals = [
          for (final m in next.tiles)
            (math.max(m.start, wantStart), math.min(m.end, wantEnd)),
          for (final g in raster.gaps) (g.start, g.end),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
        var covered = wantStart;
        for (final iv in intervals) {
          if (iv.$2 <= covered) continue;
          check(
            iv.$1 <= covered,
            'coverage hole [$covered, ${iv.$1}) in window '
            '[$wantStart, $wantEnd)',
          );
          covered = math.max(covered, iv.$2);
        }
        check(
          covered >= wantEnd,
          'window [$wantStart, $wantEnd) only covered up to $covered',
        );
        if (seen.add(_canon(next))) frontier.add((depth + 1, next));
      }
    }
    sw.stop();
    // ignore: avoid_print -- test instrumentation
    print(
      'MODEL_CHECK states=${seen.length} '
      'edges=$edges bakeEdges=$bakeEdges inputs=${inputs.length} '
      'closed=${!capped} elapsed=${sw.elapsed}',
    );
    expect(
      capped,
      isFalse,
      reason:
          'maxDepth $maxDepth stopped the BFS '
          'before closure; the reachable space outgrew the grid -- inspect '
          'the planner change before raising it',
    );
    // Hard budget on reachable states, the DETERMINISTIC growth signal: a
    // planner change that multiplies them shows up here before it silently
    // 10x's CI time. Elapsed is reported, never asserted -- wall clock on a
    // shared runner reads as a planner regression.
    expect(
      seen.length,
      lessThan(400000),
      reason:
          'model check outgrew its state budget; the reachable state '
          'space exploded -- inspect the planner change',
    );
  }, tags: 'slow');
}
