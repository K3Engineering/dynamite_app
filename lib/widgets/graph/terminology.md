## File Map

- `../graph_components.dart`: widgets, graph chrome, per-channel conversion and the shared cached-paint entry point.
- `axis_math.dart`: tick ladders, absolute tick grids and Y-range snapping.
- `envelope_renderer.dart`: absolute block-grid geometry, vertex batching and mean-line/min-max-band rasterization.
- `graph_controller.dart`: generation-aware `GraphLive` / `GraphWindow` viewport state and pan/zoom math.
- `surface_cache.dart`: the tile and reduction caches belonging to one surface.
- `block_reduction_cache.dart`: bounded direct-mapped memo of complete `BlockReduction`s in display units.
- `tile_cache.dart`: `TileMeta` texture ownership, canvas calls and `BakePump`.
- `tile_cache_functional.dart`: the entire per-frame cache decision as `stepCache`, importing only `dart:math`.

## Aggregation

| Term | Width in samples | Width on screen | Lifetime / owner |
|---|---|---|---|
| **Sample** | 1 | `pps` px (varies with zoom) | immutable once written; ring storage |
| **Bucket** | `kBucketSize = 100` | `100 · pps` px | write-time aggregates; makes reductions and Y folds O(window/100) |
| **Block** | `max(1, floor(viewSpan / gw))`, bucket-aligned when large | approximately 1 logical px | absolute-grid min/avg/max reduction; direct-mapped memo key |
| **Tile** | approximately `200px / pps` | `kTileTargetPx = 200` logical px target | `TileMeta` plus shell-owned `ui.Image`; one bake/frame |

## Sample-Space Coordinates and Edges

```text
0 ... |← retentionEdge          bakeHorizon →|  joinMargin  | fillingBlock |← dataEdge | scrollLead →
      [============= bakeable ===============][=== ~2·blockSize (unbakeable) ===]
```

- **`retentionEdge`** (`oldestSample`): left eviction boundary. Parked windows do not chase it; evicted portions draw blank.
- **`bakeHorizon`** (`totalSamples - 2·blockSize`): no new bake may end beyond it.
- **`dataEdge`** (`totalSamples`): exclusive end of written samples.
- **`scrollLead`**: the device-clock projection and fixed display lead framed beyond `dataEdge`.
- **Join margin**: complete blocks after `bakeHorizon`. They remain vector-drawn because a bake renders through its full join block.

The Y fold covers the complete block-aligned render span, not just the nominal viewport: it starts at the absolute block containing `covStart` and ends at `joinBlockEnd(covEnd)`, clamped to retained data. Thus every value a bake can rasterize participated in that bake's Y mapping.

## Viewport Modes

- **`GraphWindow(start, end, generation)`**: fixed absolute window. A different source generation reconciles to the initial viewport instead of evaluating stale indices. Static sources stay parked even at the right edge.
- **`GraphLive(span)`**: follows the live edge. A non-null span rolls both edges; null pins the left edge to retention and auto-expands the right.

`_GraphGeometry` computes the floating live projection once per update for all chart surfaces. It pattern-matches on `GraphController.viewport`; fixed windows remain integer.

## Cache Identity and Frame Flow

- `generation`: new stream; clears both caches.
- `suppressKey` (`unit`, `calibrationVersion`, and `tareVersion` when tares affect the series): suppresses mismatched tile blits and clears reductions. Its shape does not depend on channel membership.
- `ghostKey` (channel IDs), `gh`, `dpr` and scale drift: old tiles can ghost or affine-rescale during the rightmost-first refresh sweep.

`TileMeta` owns all stamps needed for comparison, including generation and bake-time `pps`; `CacheState` contains only tile metas and the next texture ID. Off-view config-stale tiles drop immediately. Off-view drift-stale tiles survive for pan-back. There is no independent size-stale predicate: drift/config staleness drives every refresh, and narrow gap fills absorb neighbors within the 1.5-target merge cap.

Each `stepCache` returns the next state plus blits, vector gaps and at most one bake request. The shell rasterizes that request and draws the frame. The renderer's logical width is always `(end - start) * pps`; no measurement crosses back from shell to core.

`BlockReductionCache` uses 8192 tagged direct-mapped slots per channel. Collisions replace entries and cause at most a later re-reduction; there is no view-dependent eviction pass.

## Preferred Terms

- **`tile`**, **`stub`**, **`retentionEdge` / `dataEdge` / `scrollLead` / `bakeHorizon`**, **`joinMargin`**, **`suppressKey` / `ghostKey`**.
- **`uncovered`** means cache holes; **`dropouts`** means `SampleStorage.gaps`.
- **`meanLine` / `minMaxBand`** and **`renderEnd`** are the renderer primitives and overshoot limit.
