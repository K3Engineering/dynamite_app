import 'package:flutter/foundation.dart';

import '../../models/bucket_series.dart';

/// Per-surface memo of completed envelope block reductions (display units),
/// keyed by absolute block index. Envelope blocks are anchored to absolute
/// sample indices and samples never change once written, so a COMPLETE
/// block's min/avg/max is immutable -- and the live-edge gap paths
/// re-reduce ~200 blocks per surface EVERY frame (see SegmentedGraphCache;
/// the measured round-8 split was reduce 46%/71% of sliver build on
/// js/wasm). One instance per painting surface, owned by the host State
/// like its SegmentedGraphCache.
///
/// Invalidation mirrors the segment cache's identity model and is checked
/// once per paint in [prepare]: a change of the data stream (generation),
/// the display mapping (the cache's destructive key: unit, calibration,
/// tares), or the block grid (blockSize) clears everything. Reductions are
/// value-space (no y-mapping), so Y-range drift needs no invalidation.
class BlockReductionCache {
  /// Per-channel memo cap. Entries cost ~40 bytes; a view holds ~1 block
  /// per logical px, so the cap binds only during long pans (off-view
  /// entries are dead weight), after which [prepare] evicts everything
  /// outside one view width of margin.
  static const int _maxEntriesPerChannel = 4096;

  /// channel -> blockIndex -> reduction.
  final Map<int, Map<int, BlockReduction>> _byChannel = {};

  int _generation = -1;
  int _blockSize = -1;
  List<Object?> _destructiveKey = const [];
  int _keepFrom = 0;
  int _keepTo = 0;

  /// Frame upkeep, called once per paint with the SAME identity values the
  /// SegmentedGraphCache gets: clears on identity change (see the class
  /// doc) and keeps the memo bounded around the visible window. The block
  /// range is [viewStart / blockSize, (viewStart + viewSpan) / blockSize)
  /// at the caller's current mapping.
  void prepare({
    required int generation,
    required List<Object?> destructiveKey,
    required int blockSize,
    required int viewBlockStart,
    required int viewBlockEnd,
  }) {
    if (generation != _generation ||
        blockSize != _blockSize ||
        !listEquals(destructiveKey, _destructiveKey)) {
      _byChannel.clear();
      _generation = generation;
      _blockSize = blockSize;
      _destructiveKey = List.of(destructiveKey);
    }
    final margin = viewBlockEnd - viewBlockStart;
    _keepFrom = viewBlockStart - margin;
    _keepTo = viewBlockEnd + margin;
    for (final blocks in _byChannel.values) {
      if (blocks.length > _maxEntriesPerChannel) {
        blocks.removeWhere((k, _) => k < _keepFrom || k > _keepTo);
      }
    }
  }

  /// The reduction for [blockIndex] of [channel]: [reduce] runs the first
  /// time a [complete] block is asked for (per identity epoch, see
  /// [prepare]); later asks are map hits. The caller reports a block
  /// incomplete when its range is still filling at the data edge or its
  /// left end is clipped by the retention edge -- such blocks are reduced
  /// on every call and never cached, matching the uncached behavior.
  BlockReduction resolve({
    required int channel,
    required int blockIndex,
    required bool complete,
    required BlockReduction Function() reduce,
  }) {
    if (!complete) return reduce();
    return _byChannel
        .putIfAbsent(channel, () => {})
        .putIfAbsent(blockIndex, reduce);
  }
}
