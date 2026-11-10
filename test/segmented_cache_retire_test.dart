import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/graph/tile_cache_functional.dart';

// Direct tests of stepCache's drop decisions (see its doc): tiles far
// outside the view, and tiles the receded horizon has retired. Driving the
// core instead of paint() is what lets these pin one tile the frame would
// otherwise have no opinion about.
//
// The visible-retirement path also has an end-to-end test in
// segmented_graph_cache_test.dart ('a stale tile the receded horizon fully
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
    int? bakeHorizon,
    double graphHeight = gh,
    List<Object?> ghostKey = const ['k'],
  }) => (
    generation: 0,
    suppressKey: const ['u'],
    ghostKey: ghostKey,
    gw: gw,
    gh: graphHeight,
    dpr: 1,
    viewStart: viewStart,
    viewSpan: viewSpan,
    yMin: 0,
    yMax: yMax,
    totalSamples: totalSamples,
    bakeHorizon: bakeHorizon ?? totalSamples,
    hPad: 4,
    vPad: 4,
  );

  TileMeta meta(
    int start,
    int end, {
    double? contentW,
    double yMax = 100,
    double gh = 100,
    double dpr = 1,
    List<Object?> suppressKey = const ['u'],
    List<Object?> ghostKey = const ['k'],
    int textureId = 0,
  }) => TileMeta(
    textureId: textureId,
    start: start,
    end: end,
    pps: (contentW ?? 50) / (end - start),
    yMin: 0,
    yMax: yMax,
    gh: gh,
    dpr: dpr,
    generation: 0,
    suppressKey: suppressKey,
    ghostKey: ghostKey,
    hPad: 4,
    vPad: 4,
  );

  CacheState stateOf(List<TileMeta> tiles, CacheConfig c) =>
      CacheState(tiles: tiles, nextTextureId: 1000);

  // Ignore a gap bake the full frame step may add after the drop decision.
  List<(int, int)> ranges(CacheState s) => [
    for (final m in s.tiles)
      if (m.textureId < 1000) (m.start, m.end),
  ];

  test('a config-stale tile with no sample left at or below the horizon '
      'is retired', () {
    // pps 25, horizon 8, window [0,16). [10,14) starts past the horizon, so
    // nothing of it can be re-baked; under the old yMax it is also stale.
    final c = config(bakeHorizon: 8);
    final state = stateOf([meta(10, 14)], c);
    final next = stepCache(state, c).state;
    expect(ranges(next), isEmpty);
  });

  test('the same tile is kept when it is fresh: a receded horizon alone '
      'does not retire a tile', () {
    // Not stale, so its pixels are still right and it keeps blitting; only a
    // re-bake is impossible. contentW is the identity width for pps 25 over 4
    // samples.
    final c = config(bakeHorizon: 8);
    final fresh = stateOf([meta(10, 14, contentW: 4 * 25)], c);
    expect(ranges(stepCache(fresh, c).state), [(10, 14)]);
    // Same range, wrong content width: now drift-stale, so it goes.
    final stale = stateOf([meta(10, 14)], c);
    expect(ranges(stepCache(stale, c).state), isEmpty);
  });

  test('a fresh narrow tile is kept with an empty refresh range', () {
    // [10,12) is fresh and entirely past the horizon. Narrowness alone is
    // not content staleness and must not turn its texture into vector work.
    final c = config(bakeHorizon: 8);
    final state = stateOf([meta(10, 12, contentW: 2 * 25)], c);
    expect(ranges(stepCache(state, c).state), [(10, 12)]);
  });

  test('a fresh wide tile with nothing left to bake plans no bake', () {
    // Window [50,66), horizon 40, tile [40,60) is fresh but wider than the
    // split threshold (20 samples * 25 px). Its horizon-clamped range is
    // [50,40), so the planner must return null instead of an empty plan.
    final c = config(viewStart: 50, bakeHorizon: 40, totalSamples: 200);
    final state = stateOf([meta(40, 60, contentW: 20 * 25)], c);
    final step = stepCache(state, c);
    expect(ranges(step.state), [(40, 60)]);
    expect(step.frame.bake, isNull);
  });

  test('a content-stale tile with nothing to bake is retired', () {
    // Same geometry, but the tile is also content-stale. Its pixels are wrong
    // and no sample of it inside the window is at or below the horizon, so
    // stepCache drops it and its range vector-draws -- rather than keeping
    // wrong pixels the sweep could never replace.
    final c = config(viewStart: 50, bakeHorizon: 40, totalSamples: 200);
    final state = stateOf([
      meta(40, 60, contentW: 20 * 25, suppressKey: const ['other']),
    ], c);
    final step = stepCache(state, c);
    expect(ranges(step.state), isEmpty);
    expect(step.frame.bake, isNull);
  });

  test('an off-view stale tile is kept so it can blit when panned back '
      'to', () {
    // [30,40) is outside the window and the horizon, but inside the eviction
    // margin (8 * target span). Retirement is about what the frame draws; an
    // off-view ghost costs nothing, and its pixels are right for its own
    // fold, so it must survive to blit when panned back to. contentW is half
    // the identity width, so it IS drift-stale -- otherwise this would pass
    // without the visibility guard.
    final c = config(bakeHorizon: 4);
    final state = stateOf([meta(30, 40, contentW: 5 * 25)], c);
    expect(ranges(stepCache(state, c).state), [(30, 40)]);
  });

  test('a tile straddling the left view edge is kept: it still has '
      'in-window samples to re-bake', () {
    // Window [16,32), tile [8,20): the horizon-clamped refresh range is
    // [16,20), so even though it is drift-stale it is not retired.
    final c = config(viewStart: 16, bakeHorizon: 20);
    final state = stateOf([meta(8, 20, contentW: 12 * 25)], c);
    expect(ranges(stepCache(state, c).state), [(8, 20)]);
  });

  test('a tile that leaves the view after a config bump cannot resurrect', () {
    final initial = config(viewSpan: 8);
    final old = [
      meta(0, 2, contentW: 50, textureId: 0),
      meta(2, 4, contentW: 50, textureId: 1),
      meta(4, 6, contentW: 50, textureId: 2),
      meta(6, 8, contentW: 50, textureId: 3),
    ];
    final changed = config(viewSpan: 8, ghostKey: const ['new']);
    // The bump refreshes only the rightmost tile; all four were in view.
    final bumped = stepCache(stateOf(old, initial), changed).state;
    // Panning [0,2) off-view must drop its old-key texture immediately.
    final panned = stepCache(
      bumped,
      config(viewStart: 2, viewSpan: 8, ghostKey: const ['new']),
    ).state;
    expect(panned.tiles.any((s) => s.start == 0), isFalse);
  });

  test('gh staleness compares each tile with the current config', () {
    final state = stateOf([
      meta(0, 8, contentW: 8 * 25, gh: 100.08),
    ], config(totalSamples: 8));
    final step = stepCache(state, config(totalSamples: 8, graphHeight: 99.95));
    expect(step.frame.bake, isNotNull, reason: '0.13 drift exceeds 0.1');
  });

  test('a quiet frame hands back the same tile list, which is how the '
      'shell knows no texture was orphaned', () {
    final c = config(totalSamples: 8);
    final state = stateOf([meta(0, 8, contentW: 8 * 25)], c);
    expect(identical(stepCache(state, c).state.tiles, state.tiles), isTrue);
    // A frame that drops something must produce a new list.
    final dropping = stateOf([
      meta(0, 8, contentW: 8 * 25),
      meta(10, 14, contentW: 4 * 25, suppressKey: const ['other']),
    ], c);
    final horizon = config(bakeHorizon: 8);
    final dropped = stepCache(dropping, horizon).state;
    expect(ranges(dropped), [(0, 8)]);
    expect(
      identical(dropped.tiles, dropping.tiles),
      isFalse,
      reason: 'a frame that drops a tile must not reuse the list',
    );
  });
}
