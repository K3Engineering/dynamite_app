import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/graph_components.dart';

/// A [SegmentRenderer] that records every invocation. Bake renders and direct
/// gap draws are distinguished by canvas identity: bakes happen on the cache's
/// internal recording canvas, gap draws on the frame canvas we pass to
/// [SegmentedGraphCache.paint].
typedef RenderCall = ({int start, int end, int texW, bool onFrameCanvas});

class _Harness {
  final cache = SegmentedGraphCache();
  final calls = <RenderCall>[];

  /// Run one [SegmentedGraphCache.paint] frame with test-friendly defaults:
  /// gw 400 x gh 100 at dpr 1 => 1 px/sample for a 400-sample window, so the
  /// bake target span equals kSegmentTargetPx samples (200). [tailSpan] is
  /// small enough (10) to leave existing coverage scenarios unaffected; the
  /// fake renderer reports tail provisionality the same way the envelope
  /// renderer does (bake end within one tail span of the data edge).
  bool paint({
    required int viewStart,
    required int viewSpan,
    required int totalSamples,
    double gw = 400,
    double gh = 100,
    double dpr = 1.0,
    double yMin = 0,
    double yMax = 100,
    int generation = 0,
    List<Object?> destructiveKey = const ['u'],
    List<Object?> remapKey = const ['k'],
    double maxDirectGapPx = double.infinity,
    int tailSpan = 10,
  }) {
    calls.clear();
    final recorder = ui.PictureRecorder();
    final frameCanvas = Canvas(recorder);
    final result = cache.paint(
      frameCanvas,
      generation: generation,
      destructiveKey: destructiveKey,
      remapKey: remapKey,
      gw: gw,
      gh: gh,
      dpr: dpr,
      viewStart: viewStart,
      viewSpan: viewSpan,
      yMin: yMin,
      yMax: yMax,
      totalSamples: totalSamples,
      tailSpan: tailSpan,
      hPad: kSegmentImagePad,
      vPad: kSegmentImagePad,
      maxDirectGapPx: maxDirectGapPx,
      render: (canvas, start, end, texW) {
        calls.add((
          start: start,
          end: end,
          texW: texW,
          onFrameCanvas: identical(canvas, frameCanvas),
        ));
        return (
          contentW: texW.toDouble(),
          tailProvisional: end + tailSpan > totalSamples,
        );
      },
    );
    recorder.endRecording().dispose();
    return result;
  }

  List<RenderCall> get bakes => calls.where((c) => !c.onFrameCanvas).toList();
  List<RenderCall> get gapDraws => calls.where((c) => c.onFrameCanvas).toList();

  void dispose() => cache.dispose();
}

void main() {
  late _Harness h;

  setUp(() => h = _Harness());
  tearDown(() => h.dispose());

  group('SegmentedGraphCache bootstrap fill', () {
    test('spends one bake per frame until the view is covered', () {
      // 400 uncovered samples at 1 px/sample => two 200-sample target bakes.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isTrue);
      expect(h.bakes, [(start: 0, end: 200, texW: 200, onFrameCanvas: false)]);
      // The still-uncovered remainder is vector-drawn on the frame canvas.
      expect(h.gapDraws, [
        (start: 200, end: 400, texW: 200, onFrameCanvas: true),
      ]);

      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isTrue);
      expect(h.bakes, [
        (start: 200, end: 400, texW: 200, onFrameCanvas: false),
      ]);

      // Fully covered and fresh: no bake work remains, no gap draws.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isFalse);
      expect(h.calls, isEmpty);
    });

    test('gaps wider than maxDirectGapPx are left blank, not vector-drawn', () {
      h.paint(
        viewStart: 0,
        viewSpan: 400,
        totalSamples: 400,
        maxDirectGapPx: 100,
      );
      // The 200px uncovered remainder exceeds the 100px direct-draw limit.
      expect(h.gapDraws, isEmpty);
    });
  });

  group('SegmentedGraphCache live-edge sliver', () {
    test('a sub-kSegmentGapBakePx sliver is drawn direct every frame, never '
        'baked', () {
      // Cover [0, 200); the remaining 20 samples (20px < 40px threshold)
      // stay a vector-drawn sliver.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 220), isTrue);
      expect(h.bakes.single.start, 0);
      expect(h.bakes.single.end, 200);

      for (int frame = 0; frame < 3; frame++) {
        expect(
          h.paint(viewStart: 0, viewSpan: 400, totalSamples: 220),
          isFalse,
        );
        expect(h.bakes, isEmpty);
        expect(h.gapDraws, [
          (start: 200, end: 220, texW: 20, onFrameCanvas: true),
        ]);
      }
    });

    test('an outgrown sliver bake absorbs its left neighbor instead of '
        'accumulating strips', () {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 250); // bakes [0,200)
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 250); // [200,250)
      expect(h.bakes.single, (
        start: 200,
        end: 250,
        texW: 50,
        onFrameCanvas: false,
      ));

      // 50 more samples arrive: the new [250, 300) gap merges with the
      // [200, 250) strip (combined width <= one target), re-baking [200, 300)
      // in place rather than adding a third sliver-wide segment.
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 300);
      expect(h.bakes.single, (
        start: 200,
        end: 300,
        texW: 100,
        onFrameCanvas: false,
      ));
    });
  });

  group('SegmentedGraphCache config staleness', () {
    /// Cover the 400-sample view (two bakes) and verify steady state.
    void fill() {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isFalse);
    }

    test('a destructiveKey change suppresses blits and sweeps right-to-left',
        () {
      fill();
      // Frame 1: the rightmost stale segment is re-baked in place; the
      // still-stale range is vector-drawn (its segment never blits).
      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          destructiveKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes, [
        (start: 200, end: 400, texW: 200, onFrameCanvas: false),
      ]);
      expect(h.gapDraws, [(start: 0, end: 200, texW: 200, onFrameCanvas: true)]);

      // Frame 2: the sweep reaches the left segment; nothing left to draw.
      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          destructiveKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes.single.start, 0);
      expect(h.gapDraws, isEmpty);

      // Converged.
      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          destructiveKey: const ['other'],
        ),
        isFalse,
      );
      expect(h.calls, isEmpty);
    });

    test('a remapKey change keeps blitting (no gap draws) and sweeps '
        'right-to-left', () {
      fill();
      // Frame 1: same rightmost-first sweep, but stale segments still blit
      // (ghosts/shifts), so nothing is vector-drawn.
      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          remapKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes, [
        (start: 200, end: 400, texW: 200, onFrameCanvas: false),
      ]);
      expect(h.gapDraws, isEmpty);

      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          remapKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes.single.start, 0);

      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          remapKey: const ['other'],
        ),
        isFalse,
      );
    });

    test('a gh change is remap staleness: kept, swept, never gap-drawn', () {
      fill();
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, gh: 120),
        isTrue,
      );
      expect(h.bakes.single.start, 200);
      expect(h.gapDraws, isEmpty);
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, gh: 120),
        isTrue,
      );
      expect(h.bakes.single.start, 0);
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, gh: 120),
        isFalse,
      );
    });

    test('a dpr change is remap staleness: kept, swept, never gap-drawn', () {
      fill();
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, dpr: 2.0),
        isTrue,
      );
      expect(h.bakes.single.start, 200);
      expect(h.gapDraws, isEmpty);
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, dpr: 2.0),
        isTrue,
      );
      expect(h.bakes.single.start, 0);
    });

    test('a generation change clears everything (new data stream)', () {
      fill();
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, generation: 1),
        isTrue,
      );
      // Re-baking from scratch, left aligned (bootstrap fill order).
      expect(h.bakes, [(start: 0, end: 200, texW: 200, onFrameCanvas: false)]);
      expect(h.gapDraws, [(start: 200, end: 400, texW: 200, onFrameCanvas: true)]);
    });

    test('a config bump disposes off-view segments (no ghost resurrection)',
        () {
      // Cover the origin and [400, 800) of a long buffer, then park on the
      // [400, 800) view: [0, 400) is covered but off-view.
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 4400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 4400);
      h.paint(viewStart: 400, viewSpan: 400, totalSamples: 4400);
      h.paint(viewStart: 400, viewSpan: 400, totalSamples: 4400);
      expect(
        h.paint(viewStart: 400, viewSpan: 400, totalSamples: 4400),
        isFalse,
      );

      // Bump the remap key: the off-view [0, 400) segments must be disposed
      // (the visible ones sweep right-to-left as usual).
      expect(
        h.paint(
          viewStart: 400,
          viewSpan: 400,
          totalSamples: 4400,
          remapKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes.single.start, 600); // rightmost visible stale segment

      // Pan back to the origin: had the stale [0, 400) segments survived,
      // they would blit (remap-stale) and cover the view -- no gap draws.
      // Instead the range is uncovered: it vector-draws and re-bakes.
      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 4400,
          remapKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes.single.start, 0);
      expect(h.gapDraws, [
        (start: 200, end: 400, texW: 200, onFrameCanvas: true),
      ]);
    });

    test('a small gw change is pure x-drift: segments are kept, no work', () {
      fill();
      // 410/400 = 2.5% scale drift, well under kMaxSegmentDrift (8%).
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, gw: 410),
        isFalse,
      );
      expect(h.calls, isEmpty);
    });

    test('clear() forces a full re-bake', () {
      fill();
      h.cache.clear();
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isTrue);
      expect(h.bakes.single.start, 0);
    });
  });

  group('SegmentedGraphCache rolling drift refresh', () {
    test('a y-range change past kMaxSegmentDrift re-bakes visible segments '
        'one per frame', () {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);

      // yMax 100 -> 120 is a 16.7% y-scale drift (> 8%): both segments are
      // stale, refreshed round-robin within the bake budget.
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, yMax: 120),
        isTrue,
      );
      expect(h.bakes.single, (
        start: 0,
        end: 200,
        texW: 200,
        onFrameCanvas: false,
      ));

      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, yMax: 120),
        isTrue,
      );
      expect(h.bakes.single.start, 200);

      // Both refreshed under the new mapping: steady state again.
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, yMax: 120),
        isFalse,
      );
    });
  });

  group('SegmentedGraphCache eviction', () {
    test('segments far outside the view are evicted and re-bake on return', () {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 4400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 4400);
      // Steady at the origin.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 4400), isFalse);

      // Jump far away: margin is kSegmentEvictionMargin * targetSpan
      // (8 * 200 = 1600 samples), so the [0, 400) segments are dropped.
      h.paint(viewStart: 4000, viewSpan: 400, totalSamples: 4400);
      expect(h.bakes.single.start, 4000);

      // Back at the origin: the old coverage is gone and must re-bake.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 4400), isTrue);
      expect(h.bakes.single.start, 0);
    });
  });

  group('SegmentedGraphCache provisional tail repair', () {
    test('a segment baked at the data edge is re-baked once its tail '
        'completes', () {
      // Bake [0, 200) with the data edge inside its tail span (205 <
      // 200 + tailSpan=10): the bake is provisional. The 5-sample sliver
      // stays a direct draw.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 205), isTrue);
      expect(h.bakes.single, (
        start: 0,
        end: 200,
        texW: 200,
        onFrameCanvas: false,
      ));

      // Tail not complete yet (209 < 200 + 10): no repair, no other work.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 209), isFalse);

      // Tail complete (210 >= 200 + 10): re-baked in place (this is what
      // erases the stale live-edge seam before it can scroll far).
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 210), isTrue);
      expect(h.bakes.single, (
        start: 0,
        end: 200,
        texW: 200,
        onFrameCanvas: false,
      ));

      // Repaired: the fresh bake's tail is complete, so no further work.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 210), isFalse);
    });

    test('repair is skipped while the segment is outside the view', () {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 205);

      // Pan right (within the eviction margin, past the data edge): the
      // tail has completed, but the segment is not visible, so no repair
      // bake is spent on it.
      expect(h.paint(viewStart: 800, viewSpan: 400, totalSamples: 210), isFalse);
      expect(h.calls, isEmpty);

      // Pan back: the stale seam is visible again and repaired.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 210), isTrue);
      expect(h.bakes.single, (
        start: 0,
        end: 200,
        texW: 200,
        onFrameCanvas: false,
      ));
    });
  });

  group('joinBlockEnd (envelope seam-join contract)', () {
    // The polyline overshoots a segment end into the first block past it
    // (the join block), and that block must reduce over its FULL natural
    // range so the join vertex equals the neighbor's vertex for the same
    // block. The old `end + blockSize` limit truncated the join block,
    // landing the vertex at a partial-data average -- the vertical seam
    // steps this guards against.
    test('is block-aligned, covers the full join block, within two blocks', () {
      for (final bs in [1, 2, 7, 20, 100]) {
        for (final end in [0, 1, 63, 199, 200, 201, 4000, 12345]) {
          final j = joinBlockEnd(end, bs);
          // Block-aligned: reduces over natural block ranges.
          expect(j % bs, 0, reason: 'end=$end bs=$bs');
          // Covers the block containing `end` AND the join block past it:
          // the last covered sample index (j - 1) lies in the join block.
          expect((j - 1) ~/ bs, (end ~/ bs) + 1, reason: 'end=$end bs=$bs');
          // Never more than two block sizes past the end -- the envelope
          // layer passes 2 * blockSize as the cache's tailSpan, and the
          // provisional-repair gate (`end + tailSpan`) must stay an upper
          // bound on the renderer's real need.
          expect(j - end, lessThanOrEqualTo(2 * bs), reason: 'end=$end bs=$bs');
          // ...and it must exceed one block size, or the join block is
          // truncated (the seam-step regression).
          expect(j - end, greaterThan(bs), reason: 'end=$end bs=$bs');
        }
      }
    });
  });
}
