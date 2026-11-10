import 'package:flutter/foundation.dart';

import '../../models/bucket_series.dart';

/// Per-surface memo of immutable envelope block reductions in display units.
///
/// Each channel has a fixed direct-mapped table. A collision replaces the old
/// entry, which only costs a later re-reduction; correctness never depends on
/// retention. Identity changes clear all channels because reductions depend on
/// the stream, display mapping and absolute block grid.
class BlockReductionCache {
  static const int _slotCount = 8192;
  static const int _slotMask = _slotCount - 1;

  final Map<int, _ChannelReductions> _byChannel = {};

  int _generation = -1;
  int _blockSize = -1;
  List<Object?> _suppressKey = const [];

  void clear() {
    _byChannel.clear();
    _generation = -1;
    _blockSize = -1;
    _suppressKey = const [];
  }

  /// Frame upkeep with the same identity values as [TileGraphCache].
  void prepare({
    required int generation,
    required List<Object?> suppressKey,
    required int blockSize,
  }) {
    if (generation == _generation &&
        blockSize == _blockSize &&
        listEquals(suppressKey, _suppressKey)) {
      return;
    }
    _byChannel.clear();
    _generation = generation;
    _blockSize = blockSize;
    _suppressKey = List.of(suppressKey);
  }

  /// Resolve one block. Incomplete edge blocks are never cached because their
  /// reduction can change as data arrives or retention advances.
  BlockReduction resolve({
    required int channel,
    required int blockIndex,
    required bool complete,
    required BlockReduction Function() reduce,
  }) {
    if (!complete) return reduce();
    final blocks = _byChannel.putIfAbsent(channel, _ChannelReductions.new);
    final slot = blockIndex & _slotMask;
    if (blocks.tags[slot] != blockIndex) {
      blocks.tags[slot] = blockIndex;
      blocks.values[slot] = reduce();
    }
    return blocks.values[slot]!;
  }
}

class _ChannelReductions {
  // Plain List<int>, not Int64List (unsupported on dart2js); exact to 2^53.
  final List<int> tags = List<int>.filled(BlockReductionCache._slotCount, -1);
  final List<BlockReduction?> values = List<BlockReduction?>.filled(
    BlockReductionCache._slotCount,
    null,
  );
}
