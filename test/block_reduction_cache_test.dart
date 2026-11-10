import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/bucket_series.dart';
import 'package:dynamite_app/widgets/graph/block_reduction_cache.dart';

/// Locks the completed-block memo contract behind the sliver optimization:
/// a complete block reduces once per identity epoch and is then served from
/// the map; incomplete blocks (live edge, retention-edge clip) reduce every
/// call and are never stored; identity changes flush everything; the memo
/// stays bounded around the visible window.
void main() {
  const r1 = (min: 1.0, max: 2.0, sum: 30.0, count: 10);
  const r2 = (min: 3.0, max: 9.0, sum: 60.0, count: 10);

  var reduces = 0;
  BlockReduction Function() runs(BlockReduction r) => () {
    reduces++;
    return r;
  };

  setUp(() => reduces = 0);

  BlockReductionCache prepared({
    int generation = 1,
    List<Object?> key = const ['u', 7],
    int blockSize = 64,
  }) {
    final cache = BlockReductionCache();
    cache.prepare(
      generation: generation,
      suppressKey: key,
      blockSize: blockSize,
    );
    return cache;
  }

  test(
    'complete blocks reduce once; blocks and channels key independently',
    () {
      final cache = prepared();
      expect(
        cache.resolve(
          channel: 0,
          blockIndex: 5,
          complete: true,
          reduce: runs(r1),
        ),
        r1,
      );
      expect(
        cache.resolve(
          channel: 0,
          blockIndex: 5,
          complete: true,
          reduce: runs(r1),
        ),
        r1,
      );
      expect(reduces, 1, reason: 'second resolve must be a map hit');

      cache.resolve(
        channel: 0,
        blockIndex: 6,
        complete: true,
        reduce: runs(r2),
      );
      expect(
        cache.resolve(
          channel: 0,
          blockIndex: 6,
          complete: true,
          reduce: runs(r2),
        ),
        r2,
      );
      expect(reduces, 2);

      cache.resolve(
        channel: 1,
        blockIndex: 5,
        complete: true,
        reduce: runs(r2),
      );
      expect(reduces, 3, reason: 'channels do not share entries');
    },
  );

  test('incomplete blocks never cache', () {
    final cache = prepared();
    for (int i = 0; i < 3; i++) {
      cache.resolve(
        channel: 0,
        blockIndex: 5,
        complete: false,
        reduce: runs(r1),
      );
    }
    expect(reduces, 3);
  });

  test('identity changes flush: generation, suppress key, block size', () {
    final cache = prepared();
    cache.resolve(channel: 0, blockIndex: 5, complete: true, reduce: runs(r1));
    expect(reduces, 1);

    void prepareWith({
      int generation = 1,
      List<Object?> key = const ['u', 7],
      int blockSize = 64,
    }) => cache.prepare(
      generation: generation,
      suppressKey: key,
      blockSize: blockSize,
    );

    prepareWith(); // identical identity: no flush
    cache.resolve(channel: 0, blockIndex: 5, complete: true, reduce: runs(r1));
    expect(reduces, 1, reason: 'same identity keeps entries');

    prepareWith(generation: 2);
    cache.resolve(channel: 0, blockIndex: 5, complete: true, reduce: runs(r1));
    expect(reduces, 2, reason: 'generation change flushes');

    // A content-equal key in a NEW list instance does not flush.
    prepareWith(generation: 2, key: ['u', 7]);
    cache.resolve(channel: 0, blockIndex: 5, complete: true, reduce: runs(r1));
    expect(reduces, 2, reason: 'key comparison is by content');

    prepareWith(generation: 2, key: ['u', 8]);
    cache.resolve(channel: 0, blockIndex: 5, complete: true, reduce: runs(r1));
    expect(reduces, 3, reason: 'key content change flushes');

    prepareWith(generation: 2, key: ['u', 8], blockSize: 32);
    cache.resolve(channel: 0, blockIndex: 5, complete: true, reduce: runs(r1));
    expect(reduces, 4, reason: 'block grid change flushes');
  });

  test('direct-mapped collisions replace entries without an eviction pass', () {
    final cache = prepared();
    cache.resolve(
      channel: 0,
      blockIndex: 100,
      complete: true,
      reduce: runs(r1),
    );
    cache.resolve(
      channel: 0,
      blockIndex: 100 + 8192,
      complete: true,
      reduce: runs(r2),
    );
    expect(reduces, 2);

    cache.resolve(
      channel: 0,
      blockIndex: 100,
      complete: true,
      reduce: runs(r1),
    );
    expect(reduces, 3, reason: 'the colliding entry was replaced');
    cache.resolve(
      channel: 0,
      blockIndex: 100 + 8192,
      complete: true,
      reduce: runs(r2),
    );
    expect(reduces, 4, reason: 'replacement works in both directions');

    // Unrelated identity upkeep does not scan or flush the table.
    cache.resolve(
      channel: 0,
      blockIndex: 100 + 8192,
      complete: true,
      reduce: runs(r2),
    );
    expect(reduces, 4);

    // Explicit clear flushes even if the next prepare passes identical keys.
    cache.clear();
    cache.prepare(generation: 1, suppressKey: const ['u', 7], blockSize: 64);
    cache.resolve(
      channel: 0,
      blockIndex: 100 + 8192,
      complete: true,
      reduce: runs(r2),
    );
    expect(reduces, 5);
  });
}
