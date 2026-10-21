import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/graph/segmented_cache_functional.dart';

// Bounded model checking of the pure cache core: BFS over the states
// REACHABLE from an empty cache under a discretized input universe
// (windows, Y ranges, config churn, generations, bake horizons), verifying
// on every single transition:
//   * the segment-list invariant (invariantViolations);
//   * fold-window / bake-horizon containment of every bake job (also
//     asserted inside planBakes; checked here independently);
//   * drops never survive into the next state;
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
// Tiers (env MODEL_CHECK_TIER): the default grid runs per PR; `full` is a
// manual pre-release sweep. Sizes below are measured on this repo, and the
// elapsed-time assertions below re-check them, so treat them as a budget to
// re-measure on planner changes, not as constants of nature:
//   * pr   -- 12-sample universe, ~143k states to closure, ~25 s here.
//   * full -- 16-sample universe, ~2.25M states, ~10 min here (it will NOT
//             fit the pr budget; MODEL_CHECK_TIER=full raises the cap).
// Reachable-state count is strongly superlinear in the universe size and
// in the number of STAMP axes (at 16 samples the full key/gh/dpr cartesian
// product alone pushes past 2M states), so the grids stay small and the
// churn set covers one representative per staleness kind (generation
// reset, destructive flip, remap flip, y-drift, receded horizon) instead
// of the product. Boundary-threshold nuance (drift just past 8%) and the
// remaining axes belong to the unit tests and the sim.

/// Deterministic canonical form: equal states (same metas, same stamps)
/// hash identically regardless of list instance or meta identity.
String _canon(CacheState s) {
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
  test(
    'reachable cache states obey the invariants',
    tags: 'slow',
    () {
    final full = Platform.environment['MODEL_CHECK_TIER'] == 'full';
    final sw = Stopwatch()..start();
    final universe = full ? 16 : 12;
    // Well past closure at both sizes (FIFO order, so arrival depth is the
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
    // destructive flip, remap flip. The full tier adds gh and dpr flips.
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
      if (full) {
        inputs.addAll([
          _config(
            viewStart: vs,
            viewSpan: 16,
            yMax: 100,
            totalSamples: universe,
            bakeableSamples: universe,
            gh: 120,
          ),
          _config(
            viewStart: vs,
            viewSpan: 16,
            yMax: 100,
            totalSamples: universe,
            bakeableSamples: universe,
            dpr: 2,
          ),
        ]);
      }
    }

    void check(bool ok, String reason) {
      if (!ok) throw StateError('model check violation: $reason');
    }

    final seen = <String>{_canon(CacheState.empty())};
    // Serial source for the shell's texture ids. Must NOT appear in _canon:
    // two states differing only in ids are the same cache state.
    var nextTextureId = 0;
    // FIFO: arrival depth is the shortest path, so the closure report is
    // meaningful (LIFO polls deep paths first and inflates depth).
    final frontier = Queue<(int, CacheState)>()..add((0, CacheState.empty()));
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
        final pre = prepareFrame(s, env);
        final plan = planBakes(pre.state, env);
        final job = plan.job;
        if (job != null) {
          check(
            job.start >= env.covStart &&
                job.end <= env.covEnd &&
                job.end <= input.bakeableSamples,
            'bake [${job.start}, ${job.end}) outside fold window '
            '[${env.covStart}, ${env.covEnd}) or past horizon '
            '${input.bakeableSamples}',
          );
        }
        final committed = applyBake(
          pre.state,
          env,
          plan,
          job == null
              ? 0
              : math
                    .max(1, ((job.end - job.start) * env.pps).ceil())
                    .toDouble(),
          nextTextureId++,
        );
        final next = committed.state;
        if (job != null) {
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
        for (final d in [...pre.drops, ...plan.drops]) {
          check(
            !next.segments.contains(d),
            'dropped meta [${d.start}, ${d.end}) survived the transition',
          );
        }
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
      'MODEL_CHECK tier=${full ? 'full' : 'pr'} states=${seen.length} '
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
    // Hard budget: a planner change that multiplies reachable states shows
    // up here before it silently 10x's CI time.
    expect(
      sw.elapsed,
      lessThan(Duration(seconds: full ? 900 : 60)),
      reason:
          'model check outgrew its tier budget; the reachable state '
          'space exploded -- inspect the planner change',
    );
  });
}
