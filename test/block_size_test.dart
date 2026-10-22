import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/bucket_series.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Pins [blockSizeFor]'s two contracts: the horizontal resolution tracks
/// samples-per-pixel, and — above two buckets per block, where the bucket
/// reduction path engages — blocks align to the absolute bucket grid.
/// Alignment is what makes a COMPLETE block's reduction independent of how
/// full the newest bucket was when it was first reduced (see
/// [BlockReductionCache]'s immutability contract).
void main() {
  const graphW = 800.0;

  test('below the bucket path a block is exactly the samples-per-pixel floor', () {
    for (final view in [1.0, 100.0, 800.0, 100.0 * graphW, 199.0 * graphW]) {
      final floor = (view / graphW).floor();
      expect(blockSizeFor(view, graphW), floor < 1 ? 1 : floor, reason: '$view');
    }
  });

  test('a sub-pixel view still yields one sample per block', () {
    expect(blockSizeFor(1, graphW), 1);
    expect(blockSizeFor(graphW / 2, graphW), 1);
  });

  test('blocks that engage the bucket path are whole bucket multiples and '
      'never finer than one block per pixel', () {
    // From two buckets up, `_drawChannelEnvelope` switches to the bucket
    // reduction, which needs a block ending on a bucket boundary to equal the
    // exact reduction. Rounding UP keeps `blocks <= width` (the aligned size
    // is never below view/width, which `floor` alone does not guarantee).
    for (final view in [
      2.5 * kBucketSize * graphW, // 250 -> 300
      3.01 * kBucketSize * graphW, // 301 -> 400
      6e5,
      1.2e6,
    ]) {
      final blockSize = blockSizeFor(view, graphW);
      expect(
        blockSize,
        greaterThanOrEqualTo(2 * kBucketSize),
        reason: 'view $view',
      );
      expect(blockSize % kBucketSize, 0, reason: 'view $view: $blockSize');
      expect(
        (view / blockSize).ceil(),
        lessThanOrEqualTo(graphW.ceil()),
        reason: 'view $view: blockSize $blockSize',
      );
    }
  });

  test('a block just under two buckets is left at its floor', () {
    // 199 samples/px: the bucket path is not engaged, so no rounding.
    expect(blockSizeFor(199.0 * graphW, graphW), 199);
  });

  test('rounding up buys alignment at the cost of resolution, never the '
      'reverse', () {
    // 201 samples/px rounds to 300 rather than 200: one vertex per pixel
    // still holds, at a quarter coarser horizontal sampling in that band.
    const view = 201.0 * graphW;
    expect(blockSizeFor(view, graphW), 300);
    expect((view / 300).ceil(), lessThanOrEqualTo(graphW.ceil()));
  });

  test('a zero-width plot fails loudly (a caller bug, not data)', () {
    expect(() => blockSizeFor(1000, 0), throwsA(isA<AssertionError>()));
  });
}
