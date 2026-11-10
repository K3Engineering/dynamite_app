import 'block_reduction_cache.dart';
import 'tile_cache.dart';

/// The two memoized stages of one envelope surface. Sharing one handle keeps
/// their generation/suppress-key upkeep driven by the same paint call.
class GraphSurfaceCache {
  final TileGraphCache tiles = TileGraphCache();
  final BlockReductionCache reductions = BlockReductionCache();

  void clear() {
    tiles.clear();
    reductions.clear();
  }

  void dispose() => clear();
}
