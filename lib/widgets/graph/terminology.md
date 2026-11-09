## File Map

- `../graph_components.dart` : widgets, axis/grid chrome, envelope vector renderer (`_drawChannelEnvelope`), and the cache-backed paint entry point (`_paintEnvelopeDataLayer`).
- `graph_controller.dart` : viewport state (`GraphLive` / `GraphWindow`) and pan/zoom math.
- `block_reduction_cache.dart` : per-surface memo of completed 1-px `BlockReduction`s in display units.
- `segmented_cache.dart` : `SegmentMeta` texture cache, staleness sweep, and `BakePump`. Raster shell: ui.Image ownership and canvas calls only.
- `segmented_cache_functional.dart` : the cache's decision core as pure functions over value types (`prepareFrame` / `planBakes` / `applyBake` / `rasterPlan`). Imports nothing but `dart:math`; purity is a review property, not a tested one.

## Aggregation

| Term | Width in samples | Width on screen | Lifetime / owner |
|---|---|---|---|
| **Sample** | 1 | `pps` px (varies with zoom) | immutable once written; ring storage |
| **Bucket** | always `kBucketSize = 100` | `100 · pps` px | write-time min/max/sum aggregates (`BucketAccumulator`); makes reductions and Y-range folds O(window/100) |
| **Block** | `max(1, floor(viewSpan / gw))` : *view-dependent* | ≈ **1 logical px** ("never more vertices than pixels") | render-time unit: 1 block → 1 min/avg/max reduction → 1 mean vertex + 1 min/max band quad; anchored to sample 0; memo key in `BlockReductionCache` |
| **Tile** | `targetSpan = round(200px / pps)` ≈ ~200 blocks | ~`kSegmentTargetPx = 200` logical px target | baked `ui.Image` (GPU texture), immutable; sweep-owned, budget 1 bake/frame |

Three aggregation widths coexist: **100 samples** (fixed, storage), **~1 px** (view-derived, render), **~200 px** (target, texture). Buckets only enter the render path when a block spans ≥ 2 buckets (`blockSize ≥ 200`); zoomed in past 1 sample/px, a block is 1 sample and buckets are bypassed.

## Sample-Space Coordinates & Edges

```text
0 ... |← retentionEdge          bakeHorizon →|  joinMargin  | fillingBlock |← dataEdge | scrollLead →
      [============= bakeable ===============][=== ~2·blockSize (unbakeable) ===]
```

- **Boundaries:**
  - **`retentionEdge`** (`oldestSample`) : left eviction boundary of the ring buffer.
  - **`bakeHorizon`** (`totalSamples - 2·blockSize`) : rightmost sample a tile bake may end at (`bakeableSamples`).
  - **`dataEdge`** (`totalSamples`) : exclusive end of written samples.
  - **`scrollLead`** : fractional lead framed right of `dataEdge`: the device-clock projection (`DeviceClock` / `GraphDataSource.projectedEndAt`, a decaying max envelope over recent deliveries) run ahead of the newest confirmed sample, plus the painter's fixed lead. Lets the window glide at the device oscillator's rate between bursty packet deliveries.
- **Zones (right to left):**
  1. **Filling block** : partial block containing `dataEdge`; reduced fresh every frame, never memoized.
  2. **Join margin** : complete, memoized blocks in `[bakeHorizon, fillingBlock)`. Unbakeable because a tile ending at `bakeHorizon` overshoots 1 block right (`joinBlockEnd`) so its seam vertex matches the future neighbor's.
  3. **Uncovered ranges** : bake-eligible sample ranges left of `bakeHorizon` not yet in a tile; vector-drawn every frame alongside 1 and 2.
  4. **Baked tiles** : `ui.Image` textures blitted under a corrective affine transform.

## Viewport Modes (`GraphController`)

- **Parked (`GraphWindow`)** : fixed `[start, end)`; does not chase `retentionEdge` (evicted portions clip blank).
- **Live (`GraphLive`)** : follows `dataEdge` in two sub-modes:
  - **Rolling (`span != null`)** : fixed span, both edges float on `dataEdge + scrollLead`.
  - **Auto-span (`span == null`)** : left edge retention-pinned, right edge floats on `dataEdge + scrollLead`.

Both variants ticker-drive `_computeGeometry` (`_GraphGeometry`, the one window snapshot every surface paints from) while the stream is fresh; parked stays integer.

## Cache Invalidation & Bake Gates

- **3-tier invalidation:**
  - `generation` (stream reset) → clears `BlockReductionCache` and the tile cache.
  - `destructiveKey` (unit, calibration, tares) → clears `BlockReductionCache`; suppresses tile blits in the cache (draws blank until swept).
  - `remapKey` (channels) + `gh` / `dpr` / scale drift → tiles keep blitting as ghosts or affine-rescaled while swept rightmost-first.
- **3 bake gates:**
  1. **Content gate (correctness):** tile `end ≤ bakeHorizon`.
  2. **Width gate (policy):** uncovered range must exceed `kSegmentGapBakePx = 40` logical px; narrower **stubs** vector-draw or get swallowed into an adjacent bake.
  3. **Throughput gate (rate limit):** one bake per frame (`planBakes` returns at most one plan), right-aligned to at most `targetSpan` (plus left-stub swallow).

## Preferred Terms

- Prefer **`tile`** over *segment*.
- Prefer **`stub`** over *sliver* .
- Prefer **`retentionEdge` / `dataEdge` / `scrollLead` / `bakeHorizon`** over overloaded *live edge* or *retention head*.
- Prefer **`joinMargin`** over *horizon zone* (`bakeHorizon` is the boundary line; the margin is the 2-block strip between `bakeHorizon` and `dataEdge`).
- Prefer **`uncovered`** (cache holes) vs **`dropouts`** (missing-packet ranges in `SampleStorage.gaps`) over using *gap* for both.
- Prefer **`suppressKey` / `ghostKey`** over *destructiveKey / remapKey* (`suppressKey` suppresses blits without destroying coverage; `ghostKey` is channel membership, not coordinate remapping). The code still uses the latter names; the rename is the TODO below.
- Prefer **`meanLine` / `minMaxBand`** (`bandEnd`) for the two primitives inside the **envelope** layer (`_drawChannelEnvelope`), and **`renderEnd`** over `totalSamples` for the overshoot-capped sample limit passed into it.

## TODO

- Rename symbols across `segmented_cache.dart`, `block_reduction_cache.dart`, `graph_controller.dart`, and `graph_components.dart` to match the preferred terms above (tile, stub, suppressKey/ghostKey, bakeHorizon).
