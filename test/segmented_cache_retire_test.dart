import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/graph/segmented_cache_functional.dart';

// Direct tests of prepareFrame's drop decisions (see its doc): segments far
// outside the view, and segments the receded horizon has retired. Driving the
// core instead of paint() is what lets these pin one segment the frame would
// otherwise have no opinion about.
//
// The visible-retirement path also has an end-to-end test in
// segmented_graph_cache_test.dart ('a stale segment the receded horizon fully
// overtakes stops blitting ...'); these cover the cases paint() cannot reach
// deterministically.
void main() {
  const gw = 400.0;
  const gh = 100.0;

  CacheConfig config({
    double viewStart = 0,
    double viewSpan = 16,
    double yMax = 100,
    int totalSamples = 64,
    int? bakeableSamples,
  }) => (
    generation: 0,
    destructiveKey: const ['u'],
    remapKey: const ['k'],
    gw: gw,
    gh: gh,
    dpr: 1,
    viewStart: viewStart,
    viewSpan: viewSpan,
    yMin: 0,
    yMax: yMax,
    totalSamples: totalSamples,
    bakeableSamples: bakeableSamples ?? totalSamples,
    hPad: 4,
    vPad: 4,
  );

  SegmentMeta meta(
    int start,
    int end, {
    double contentW = 50,
    double yMax = 100,
    double gh = 100,
    double dpr = 1,
    List<Object?> destructiveKey = const ['u'],
    List<Object?> remapKey = const ['k'],
    int textureId = 0,
  }) => SegmentMeta(
    textureId: textureId,
    start: start,
    end: end,
    contentW: contentW,
    yMin: 0,
    yMax: yMax,
    gh: gh,
    dpr: dpr,
    destructiveKey: destructiveKey,
    remapKey: remapKey,
    hPad: 4,
    vPad: 4,
  );

  CacheState stateOf(List<SegmentMeta> segments, CacheConfig c) =>
      CacheState.fresh(c).withSegments(segments);

  List<(int, int)> ranges(CacheState s) => [
    for (final m in s.segments) (m.start, m.end),
  ];

  test('a config-stale segment with no sample left at or below the horizon '
      'is retired', () {
    // pps 25, horizon 8, window [0,16). [10,14) starts past the horizon, so
    // nothing of it can be re-baked; under the old yMax it is also stale.
    final c = config(bakeableSamples: 8);
    final state = stateOf([meta(10, 14)], c);
    final next = prepareFrame(state, cacheEnvFor(c));
    expect(ranges(next), isEmpty);
  });

  test('the same segment is kept when it is fresh: a receded horizon alone '
      'does not retire a segment', () {
    // Not stale, so its pixels are still right and it keeps blitting; only a
    // re-bake is impossible. contentW is the identity width for pps 25 over 4
    // samples.
    final c = config(bakeableSamples: 8);
    final fresh = stateOf([meta(10, 14, contentW: 4 * 25)], c);
    expect(ranges(prepareFrame(fresh, cacheEnvFor(c))), [(10, 14)]);
    // Same range, wrong content width: now drift-stale, so it goes.
    final stale = stateOf([meta(10, 14)], c);
    expect(ranges(prepareFrame(stale, cacheEnvFor(c))), isEmpty);
  });

  test('a size-stale segment is never retired, even with an empty refresh '
      'range', () {
    // [10,12) is 50 px at pps 25 -- under half a 200 px target, and entirely
    // past the horizon, so its refresh range is empty. It is NOT content
    // stale, though, and dropping it would turn a blittable strip into
    // vectors drawn every frame.
    final c = config(bakeableSamples: 8);
    final state = stateOf([meta(10, 12, contentW: 2 * 25)], c);
    expect(ranges(prepareFrame(state, cacheEnvFor(c))), [(10, 12)]);
  });

  test('a size-stale segment with nothing left to bake plans no bake', () {
    // Window [50,66), horizon 40, tile [40,60) is fresh but over two targets
    // wide (20 samples * 25 px). Its only re-bake would be the horizon-clamped
    // range [50,40) -- empty -- so the planner must return null rather than an
    // empty plan the caller has to filter.
    final c = config(viewStart: 50, bakeableSamples: 40, totalSamples: 200);
    final state = stateOf([meta(40, 60, contentW: 20 * 25)], c);
    final env = cacheEnvFor(c);
    final prepared = prepareFrame(state, env);
    expect(ranges(prepared), [(40, 60)]);
    expect(planBakes(prepared, env), isNull);
  });

  test('a content-stale tile with nothing left to bake is retired instead', () {
    // Same geometry, but the tile is also content-stale. Its pixels are wrong
    // and no sample of it inside the window is at or below the horizon, so
    // prepareFrame drops it and its range vector-draws -- rather than keeping
    // wrong pixels the sweep could never replace.
    final c = config(viewStart: 50, bakeableSamples: 40, totalSamples: 200);
    final state = stateOf([
      meta(40, 60, contentW: 20 * 25, destructiveKey: const ['other']),
    ], c);
    final env = cacheEnvFor(c);
    final prepared = prepareFrame(state, env);
    expect(ranges(prepared), isEmpty);
    expect(planBakes(prepared, env), isNull);
  });

  test('an off-view stale segment is kept so it can blit when panned back '
      'to', () {
    // [30,40) is outside the window and the horizon, but inside the eviction
    // margin (8 * target span). Retirement is about what the frame draws; an
    // off-view ghost costs nothing, and its pixels are right for its own
    // fold, so it must survive to blit when panned back to. contentW is half
    // the identity width, so it IS drift-stale -- otherwise this would pass
    // without the visibility guard.
    final c = config(bakeableSamples: 4);
    final state = stateOf([meta(30, 40, contentW: 5 * 25)], c);
    expect(ranges(prepareFrame(state, cacheEnvFor(c))), [(30, 40)]);
  });

  test('a segment straddling the left view edge is kept: it still has '
      'in-window samples to re-bake', () {
    // Window [16,32), tile [8,20): the horizon-clamped refresh range is
    // [16,20), so even though it is drift-stale it is not retired.
    final c = config(viewStart: 16, bakeableSamples: 20);
    final state = stateOf([meta(8, 20, contentW: 12 * 25)], c);
    expect(ranges(prepareFrame(state, cacheEnvFor(c))), [(8, 20)]);
  });

  test('a quiet frame hands back the same segment list, which is how the '
      'shell knows no texture was orphaned', () {
    final c = config();
    final state = stateOf([meta(0, 8, contentW: 8 * 25)], c);
    final env = cacheEnvFor(c);
    expect(
      identical(prepareFrame(state, env).segments, state.segments),
      isTrue,
    );
    // A frame that drops something must produce a new list.
    final dropping = stateOf([
      meta(0, 8, contentW: 8 * 25),
      meta(10, 14, contentW: 4 * 25, destructiveKey: const ['other']),
    ], c);
    final horizon = config(bakeableSamples: 8);
    final dropped = prepareFrame(dropping, cacheEnvFor(horizon));
    expect(ranges(dropped), [(0, 8)]);
    expect(
      identical(dropped.segments, dropping.segments),
      isFalse,
      reason: 'a frame that drops a segment must not reuse the list',
    );
  });
}
