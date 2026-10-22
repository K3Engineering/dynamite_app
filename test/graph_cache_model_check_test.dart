import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/graph/segmented_cache_functional.dart';

// Bounded model checking of the pure cache core: BFS over the states
// REACHABLE from an empty cache under a discretized input universe
// (windows, Y ranges, config churn, generations, bake horizons), verifying
// on every single transition:
//   * the segment-list invariant (invariantViolations);
//   * fold-window / bake-horizon containment of every bake (also asserted
//     inside planBakes; checked here independently);
//   * texture ids stay unique, so the shell's reconcile-by-id frees only
//     textures no segment names;
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
// One tier, sized for the per-PR suite: a 12-sample universe reaching
// closure at ~143k states in ~25 s measured on this repo. The grid is
// re-checked by the state-count budget below, so treat that as a budget to
// re-measure on planner changes, not a constant of nature. Reachable-state
// count is strongly superlinear in the universe size and in the number of
// STAMP axes (a gh or dpr flip alone triples it), so the grid stays small and
// the churn set covers one representative per staleness kind (generation
// reset, destructive flip, remap flip, y-drift, receded horizon) instead of
// the product. Boundary-threshold nuance (drift just past 8%) belongs to the
// unit tests and the sim.

/// Deterministic canonical form: equal states (same metas, same stamps) hash
/// identically regardless of list instance or meta identity. Null is the
/// unstamped pre-first-frame state (see [prepareFrame]), which no real state
/// can canonicalize to (`_canon` always emits stamps).
String _canon(CacheState? s) {
  if (s == null) return '#none';
  final b = StringBuffer('g${s.generation};${s.gh};${s.dpr};');
  b.writeAll(s.destructiveKey.map((k) => 'u$k'));
  b.writeAll(s.remapKey.map((k) => 'r$k'));
  b.write('|');
  for (final m in s.segments) {
    b.write(
      '${m.start},${m.end},${m.contentW},${m.yMin},${m.yMax},'
      '${m.gh},${m.dpr},${m.hPad},${m.vPad},',
    );
    b.writeAll(m.destructiveKey.map((k) => 'u$k'));
    b.writeAll(m.remapKey.map((k) => 'r$k'));
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
  required int bakeableSamples,
  int generation = 0,
  String destKey = 'u1',
  String remapKey = 'k1',
  double gh = 100,
  double dpr = 1,
}) => (
  generation: generation,
  destructiveKey: [destKey],
  remapKey: [remapKey],
  gw: 400,
  gh: gh,
  dpr: dpr,
  viewStart: viewStart,
  viewSpan: viewSpan,
  yMin: 0,
  yMax: yMax,
  totalSamples: totalSamples,
  bakeableSamples: bakeableSamples,
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
            bakeableSamples: universe,
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
            bakeableSamples: universe,
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
            bakeableSamples: universe,
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
            bakeableSamples: bakeable,
          ),
        );
      }
      inputs.addAll([
        _config(
          viewStart: vs,
          viewSpan: 16,
          yMax: 100,
          totalSamples: universe,
          bakeableSamples: universe,
          generation: 1,
        ),
        _config(
          viewStart: vs,
          viewSpan: 16,
          yMax: 100,
          totalSamples: universe,
          bakeableSamples: universe,
          destKey: 'u2',
        ),
        _config(
          viewStart: vs,
          viewSpan: 16,
          yMax: 100,
          totalSamples: universe,
          bakeableSamples: universe,
          remapKey: 'k2',
        ),
      ]);
    }

    void check(bool ok, String reason) {
      if (!ok) throw StateError('model check violation: $reason');
    }

    // Reachable states, seeded with the unstamped start state; the count is
    // the deterministic growth signal the budget at the end checks.
    final seen = <String>{_canon(null)};
    // Serial source for the shell's texture ids. Must NOT appear in _canon:
    // two states differing only in ids are the same cache state.
    var nextTextureId = 0;
    // FIFO (arrival depth is the shortest path, so the closure report is
    // meaningful) seeded with "no state yet": the unstamped cache is a state
    // of its own, and the only one that is null.
    final frontier = Queue<(int, CacheState?)>()..add((0, null));
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
        final prepared = prepareFrame(s, env);
        final plan = planBakes(prepared, env);
        if (plan != null) {
          check(
            plan.start >= env.covStart &&
                plan.end <= env.covEnd &&
                plan.end <= input.bakeableSamples,
            'bake [${plan.start}, ${plan.end}) outside fold window '
            '[${env.covStart}, ${env.covEnd}) or past horizon '
            '${input.bakeableSamples}',
          );
        }
        // The shell's half of the frame, faked: the rendered width the
        // render closure would report, and the serial id it would file under.
        final measured = switch (plan) {
          final BakePlan p => (
            plan: p,
            output: (
              contentW: math
                  .max(1, ((p.end - p.start) * env.pps).ceil())
                  .toDouble(),
              textureId: nextTextureId++,
            ),
          ),
          null => null,
        };
        final committed = applyBake(prepared, env, measured);
        final next = committed.state;
        if (plan != null) {
          bakeEdges++;
          // Progress: a bake frame must move the state, so a constant
          // input cannot re-bake identical pixels next frame.
          check(
            _canon(next) != sCanon,
            'bake under a constant input changed nothing',
          );
          check(
            committed.baked != null &&
                committed.baked!.textureId == nextTextureId - 1,
            'a committed bake reported no meta',
          );
        } else {
          check(committed.baked == null, 'a quiet frame reported a bake');
        }
        final violations = invariantViolations(next);
        check(violations.isEmpty, violations.join('; '));
        // Retirement, stated without the core's own predicate so it is a real
        // net: no segment prepareFrame hands on may be past the eviction
        // margin, nor content-stale with no sample left inside the window at
        // or below the horizon. The latter is the case that matters: such a
        // segment blits frozen pixels in the horizon zone forever, because the
        // sweep could only drop it, never re-bake it.
        //
        // Kept segments only. The other direction (a fresh segment must not be
        // retired) is not expressible this way: prepareFrame also drops
        // off-view segments on a config bump, so "dropped implies stale" is
        // false by design. segmented_cache_retire_test pins that direction.
        bool pastMargin(SegmentMeta m) =>
            m.end < env.covStart - kSegmentEvictionMargin * env.targetSpan ||
            m.start > env.covEnd + kSegmentEvictionMargin * env.targetSpan;
        bool contentStale(SegmentMeta m) =>
            !_sameKey(m.destructiveKey, prepared.destructiveKey) ||
            !_sameKey(m.remapKey, prepared.remapKey) ||
            (m.gh - prepared.gh).abs() > 0.1 ||
            m.dpr != prepared.dpr ||
            math.max(
                  (1 - (m.end - m.start) * env.pps / m.contentW).abs(),
                  (1 - (m.yMax - m.yMin) / (input.yMax - input.yMin)).abs(),
                ) >
                kMaxSegmentDrift;
        bool noRefreshableSample(SegmentMeta m) =>
            math.min(m.end, math.min(input.bakeableSamples, env.covEnd)) <=
            math.max(m.start, env.covStart);
        bool shouldRetire(SegmentMeta m) =>
            m.end > env.covStart &&
            m.start < env.covEnd &&
            contentStale(m) &&
            noRefreshableSample(m);
        for (final m in prepared.segments) {
          check(
            !pastMargin(m) && !shouldRetire(m),
            'prepareFrame kept [${m.start},${m.end}) '
            '(pastMargin=${pastMargin(m)} shouldRetire=${shouldRetire(m)}) '
            'at win=[${env.covStart},${env.covEnd}) '
            'horizon=${input.bakeableSamples}',
          );
        }
        // Segments the frame dropped are gone from the state, and every
        // surviving segment's texture id is unique -- the shell reconciles its
        // texture map against exactly this list (see _reconcileTextures), so a
        // survived drop would free a texture still in use.
        final ids = {for (final m in next.segments) m.textureId};
        check(
          ids.length == next.segments.length,
          'two segments share a texture id',
        );
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
        final raster = rasterPlan(next, env);
        final intervals = [
          for (final m in next.segments)
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
  });
}
