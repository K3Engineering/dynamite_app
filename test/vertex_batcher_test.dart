import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/graph_components.dart';

/// Unit tests for [VertexBatcher], the fixed-capacity vertex accumulator that
/// keeps draw calls under the web (Skwasm/Emscripten) 4096-float stack limit.
///
/// Notes on the contract exercised here:
///  * [VertexBatcher.flush] emits only when strictly MORE than [drawThreshold]
///    floats are filled. The envelope renderers construct batchers with
///    `preserveFloats == drawThreshold`, so after a flush (which leaves exactly
///    `preserveFloats` floats behind) a second flush with no new vertices must
///    be a no-op — otherwise the carried-over joint would be double-drawn.
///  * The flushed view aliases the internal buffer, so consumers must copy it
///    before the next add/flush (both real consumers draw synchronously).
void main() {
  /// Collects a deep copy of every flushed view (the view itself aliases the
  /// batcher's reusable buffer).
  (VertexBatcher, List<List<double>>) makeBatcher({
    required int preserveFloats,
    required int drawThreshold,
    int capacity = 4096,
  }) {
    final flushes = <List<double>>[];
    final batcher = VertexBatcher(
      preserveFloats: preserveFloats,
      drawThreshold: drawThreshold,
      capacity: capacity,
      onFlush: (view) => flushes.add(List.of(view)),
    );
    return (batcher, flushes);
  }

  group('VertexBatcher.flush threshold', () {
    test('emits nothing when filled floats == drawThreshold', () {
      final (batcher, flushes) = makeBatcher(
        preserveFloats: 2,
        drawThreshold: 2,
      );
      batcher.add(1, 2); // exactly 2 floats == threshold, not past it
      batcher.flush();
      expect(flushes, isEmpty);

      // The pending vertex was kept: one more vertex pushes past the
      // threshold and both come out.
      batcher.add(3, 4);
      batcher.flush();
      expect(flushes, [
        [1, 2, 3, 4],
      ]);
    });

    test('a second flush with no new vertices is a no-op (no double draw)',
        () {
      // preserveFloats == drawThreshold, as in _envelopeBatchers.
      final (batcher, flushes) = makeBatcher(
        preserveFloats: 2,
        drawThreshold: 2,
      );
      batcher.add(1, 2);
      batcher.add(3, 4);
      batcher.flush();
      expect(flushes, hasLength(1));

      // Only the carried-over joint remains (2 floats == threshold).
      batcher.flush();
      batcher.flush();
      expect(flushes, hasLength(1));
    });

    test('an empty batcher never emits', () {
      final (batcher, flushes) = makeBatcher(
        preserveFloats: 4,
        drawThreshold: 4,
      );
      batcher.flush();
      expect(flushes, isEmpty);
    });
  });

  group('VertexBatcher carry-over', () {
    test('polyline (preserveFloats: 2) restarts from the last vertex', () {
      final (batcher, flushes) = makeBatcher(
        preserveFloats: 2,
        drawThreshold: 2,
      );
      batcher.add(0, 10);
      batcher.add(1, 11);
      batcher.add(2, 12);
      batcher.flush();
      expect(flushes.single, [0, 10, 1, 11, 2, 12]);

      // The next chunk begins with the previous chunk's final vertex, so the
      // stitched polyline is continuous.
      batcher.add(3, 13);
      batcher.flush();
      expect(flushes[1], [2, 12, 3, 13]);
    });

    test('triangle strip (preserveFloats: 4) carries the last two vertices',
        () {
      final (batcher, flushes) = makeBatcher(
        preserveFloats: 4,
        drawThreshold: 4,
      );
      for (int i = 0; i < 4; i++) {
        batcher.add(i.toDouble(), 100.0 + i);
      }
      batcher.flush();
      expect(flushes.single, [0, 100, 1, 101, 2, 102, 3, 103]);

      batcher.add(4, 104);
      batcher.flush();
      // Last two vertices of the previous chunk + the new one: the strip's
      // shared edge is preserved across the flush boundary.
      expect(flushes[1], [2, 102, 3, 103, 4, 104]);
    });
  });

  group('VertexBatcher.wouldOverflow', () {
    test('is exact at the capacity boundary', () {
      final (batcher, _) = makeBatcher(
        preserveFloats: 2,
        drawThreshold: 2,
        capacity: 8,
      );
      batcher.add(1, 1);
      batcher.add(2, 2);
      batcher.add(3, 3); // 6 floats filled
      expect(batcher.wouldOverflow(2), isFalse); // 8 == capacity fits
      expect(batcher.wouldOverflow(3), isTrue); // 9 > capacity
    });
  });

  group('VertexBatcher fill-flush-fill cycle', () {
    test('a long polyline is reproduced exactly when chunks are stitched', () {
      // Mirror the real usage in drawChannelEnvelope: add a vertex, then
      // flush when the NEXT add would overflow.
      final (batcher, flushes) = makeBatcher(
        preserveFloats: 2,
        drawThreshold: 2,
        capacity: 10,
      );
      const n = 23;
      for (int i = 0; i < n; i++) {
        batcher.add(i.toDouble(), (i * 2).toDouble());
        if (batcher.wouldOverflow(2)) batcher.flush();
      }
      batcher.flush();

      expect(flushes.length, greaterThan(1));
      // Every chunk fits in the capacity (the web stack limit analogue).
      for (final chunk in flushes) {
        expect(chunk.length, lessThanOrEqualTo(10));
      }
      // Stitch: drop each subsequent chunk's carried-over first vertex.
      final stitched = <double>[
        ...flushes.first,
        for (final chunk in flushes.skip(1)) ...chunk.skip(2),
      ];
      final expected = Float32List.fromList([
        for (int i = 0; i < n; i++) ...[i.toDouble(), (i * 2).toDouble()],
      ]);
      expect(stitched, expected);
    });
  });
}
