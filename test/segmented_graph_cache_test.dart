import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
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
  /// bake target span equals kSegmentTargetPx samples (200). [bakeableSamples]
  /// defaults to [totalSamples] (no reserved tail), so coverage scenarios are
  /// unaffected unless a test sets an explicit bake horizon.
  bool paint({
    required double viewStart,
    required double viewSpan,
    required int totalSamples,
    int? bakeableSamples,
    double gw = 400,
    double gh = 100,
    double dpr = 1.0,
    double yMin = 0,
    double yMax = 100,
    int generation = 0,
    List<Object?> destructiveKey = const ['u'],
    List<Object?> remapKey = const ['k'],
  }) {
    calls.clear();
    final recorder = ui.PictureRecorder();
    final frameCanvas = Canvas(recorder);
    final result = cache.paint(frameCanvas, (
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
      bakeableSamples: bakeableSamples ?? totalSamples,
      hPad: kSegmentImagePad,
      vPad: kSegmentImagePad,
      render: (canvas, start, end, texW) {
        calls.add((
          start: start,
          end: end,
          texW: texW,
          onFrameCanvas: identical(canvas, frameCanvas),
        ));
        return texW.toDouble();
      },
    ));
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
    test('spends one bake per frame until the view is covered, rightmost '
        'first', () {
      // 400 uncovered samples at 1 px/sample => two 200-sample target bakes;
      // an over-wide gap bakes its RIGHT slice first (see _bakeWidestGap).
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isTrue);
      expect(h.bakes, [
        (start: 200, end: 400, texW: 200, onFrameCanvas: false),
      ]);
      // The still-uncovered remainder is vector-drawn on the frame canvas.
      expect(h.gapDraws, [
        (start: 0, end: 200, texW: 200, onFrameCanvas: true),
      ]);

      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isTrue);
      expect(h.bakes, [(start: 0, end: 200, texW: 200, onFrameCanvas: false)]);

      // Fully covered and fresh: no bake work remains, no gap draws.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isFalse);
      expect(h.calls, isEmpty);
    });
  });

  group('SegmentedGraphCache live-edge sliver', () {
    test('a sub-kSegmentGapBakePx sliver is drawn direct every frame, never '
        'baked', () {
      // Exactly cover [0, 200); 20 trickling samples then form a 20px sliver
      // past the coverage (< 40px threshold), drawn direct from then on.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 200), isTrue);
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
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 200); // bakes [0,200)
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

    test('a wide-gap bake swallows a sub-threshold remainder instead of '
        'orphaning it', () {
      h.paint(viewStart: 0, viewSpan: 600, gw: 600, totalSamples: 200);

      // 230 samples arrive at once: the gap's right slice would be
      // [230, 430), leaving a 30px remainder (< threshold) next to the
      // [0, 200) coverage. Narrower than the threshold it needs to ever
      // bake, it would vector-draw forever -- so the bake widens to cover
      // the whole gap (230 samples > one 200-sample target span).
      expect(
        h.paint(viewStart: 0, viewSpan: 600, gw: 600, totalSamples: 430),
        isTrue,
      );
      expect(h.bakes.single, (
        start: 200,
        end: 430,
        texW: 230,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, isEmpty);
    });
  });

  group('SegmentedGraphCache config staleness', () {
    /// Cover the 400-sample view (two bakes) and verify steady state.
    void fill() {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isFalse);
    }

    test(
      'a destructiveKey change suppresses blits and sweeps right-to-left',
      () {
        fill();
        // Frame 1: the rightmost stale segment is re-baked in place; the
        // still-stale range draws nothing -- blank-then-refill, suppressed
        // segments never vector-redraw.
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
        expect(h.gapDraws, isEmpty);

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
      },
    );

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
      // Re-baking from scratch, right aligned (bootstrap fill order).
      expect(h.bakes, [
        (start: 200, end: 400, texW: 200, onFrameCanvas: false),
      ]);
      expect(h.gapDraws, [
        (start: 0, end: 200, texW: 200, onFrameCanvas: true),
      ]);
    });

    test(
      'a config bump disposes off-view segments (no ghost resurrection)',
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
        expect(h.bakes.single.start, 200);
        expect(h.gapDraws, [
          (start: 0, end: 200, texW: 200, onFrameCanvas: true),
        ]);
      },
    );

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
      expect(h.bakes.single.start, 200); // right slice of the wide gap
    });
  });

  group('SegmentedGraphCache rolling drift refresh', () {
    test('a y-range change past kMaxSegmentDrift re-bakes visible segments '
        'one per frame', () {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);

      // yMax 100 -> 120 is a 16.7% y-scale drift (> 8%): both segments are
      // stale, refreshed rightmost-first within the bake budget.
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, yMax: 120),
        isTrue,
      );
      expect(h.bakes.single, (
        start: 200,
        end: 400,
        texW: 200,
        onFrameCanvas: false,
      ));

      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, yMax: 120),
        isTrue,
      );
      expect(h.bakes.single.start, 0);

      // Both refreshed under the new mapping: steady state again.
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, yMax: 120),
        isFalse,
      );
    });
  });

  group('SegmentedGraphCache vertical stretch suppression', () {
    /// Cover the 400-sample view (two bakes) and verify steady state.
    void fill() {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isFalse);
    }

    test('an extreme y-range collapse suppresses the blit; the range '
        'draws nothing until re-baked', () {
      fill();
      // yMax 100 -> 5 stretches the tiles 20x: the baked line would cover
      // 40% of the plot height (> 25% cap), so the stale segment never
      // blits and its range draws nothing (blank-then-refill). The config
      // sweep re-bakes rightmost-first (the channel switch-off scenario).
      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          yMax: 5,
          remapKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes.single.start, 200);
      expect(h.gapDraws, isEmpty);

      // Frame 2: the sweep re-bakes the left segment; everything blits again.
      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          yMax: 5,
          remapKey: const ['other'],
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
          yMax: 5,
          remapKey: const ['other'],
        ),
        isFalse,
      );
      expect(h.calls, isEmpty);
    });

    test('suppression also applies to pure y-drift (no config change)', () {
      fill();
      // Same collapse without a key bump: the drift refresh owns the
      // re-bake (rightmost-first); the still-stretched segment's range
      // draws nothing.
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, yMax: 5),
        isTrue,
      );
      expect(h.bakes.single.start, 200);
      expect(h.gapDraws, isEmpty);

      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, yMax: 5),
        isTrue,
      );
      expect(h.bakes.single.start, 0);
      expect(h.gapDraws, isEmpty);
    });

    test('a moderate stretch keeps blitting (no suppression)', () {
      fill();
      // yMax 100 -> 60: 1.67x stretch, the line would cover ~3% of the
      // plot. Past kMaxSegmentDrift so the refresh still re-bakes, but the
      // stale blit is shown meanwhile.
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, yMax: 60),
        isTrue,
      );
      expect(h.gapDraws, isEmpty);
    });

    test('shrinkage never suppresses (a shrinking blit only sharpens)', () {
      fill();
      // yMax 100 -> 2000: 0.05x vertical shrink. Past the drift threshold
      // (refresh fires) but suppression is one-sided.
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, yMax: 2000),
        isTrue,
      );
      expect(h.gapDraws, isEmpty);
    });

    test('a range snap-back makes suppressed segments blittable again', () {
      fill();
      // Collapse + remap: the left range draws nothing this frame, the
      // right segment is re-baked at the collapsed range.
      h.paint(
        viewStart: 0,
        viewSpan: 400,
        totalSamples: 400,
        yMax: 5,
        remapKey: const ['other'],
      );
      expect(h.gapDraws, isEmpty);

      // Snap back to the original mapping and keys: the kept left segment
      // blits exactly again; the re-baked right segment is config-stale but
      // blittable (a shrink ghost) while the sweep re-bakes it.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isTrue);
      expect(h.bakes.single.start, 200);
      expect(h.gapDraws, isEmpty);
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
      expect(h.bakes.single.start, 4200); // right slice of the wide gap

      // Back at the origin: the old coverage is gone and must re-bake.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 4400), isTrue);
      expect(h.bakes.single.start, 200);
    });
  });

  group('SegmentedGraphCache bake horizon', () {
    test('the span past the horizon is never baked and vector-draws every '
        'frame', () {
      // 390 bakeable of 400 total: bakes cover [0, 390) right-to-left, the
      // [390, 400) tail stays a direct draw forever.
      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          bakeableSamples: 390,
        ),
        isTrue,
      );
      expect(h.bakes.single, (
        start: 190,
        end: 390,
        texW: 200,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, [
        (start: 0, end: 190, texW: 190, onFrameCanvas: true),
        (start: 390, end: 400, texW: 10, onFrameCanvas: true),
      ]);

      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          bakeableSamples: 390,
        ),
        isTrue,
      );
      expect(h.bakes.single, (
        start: 0,
        end: 190,
        texW: 190,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws.single, (
        start: 390,
        end: 400,
        texW: 10,
        onFrameCanvas: true,
      ));

      // Fully covered to the horizon: no more bake work, only the tail draw.
      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          bakeableSamples: 390,
        ),
        isFalse,
      );
      expect(h.gapDraws.single, (
        start: 390,
        end: 400,
        texW: 10,
        onFrameCanvas: true,
      ));
    });

    test('an advancing horizon frees the tail to bake', () {
      // First two frames cover [0, 340); the [340, 400) tail direct-draws.
      h.paint(
        viewStart: 0,
        viewSpan: 400,
        totalSamples: 400,
        bakeableSamples: 340,
      );
      h.paint(
        viewStart: 0,
        viewSpan: 400,
        totalSamples: 400,
        bakeableSamples: 340,
      );

      // Data arrives: the horizon passes the old tail, which is now baked
      // like any other uncovered range -- here grown past the gap-bake
      // threshold. It bakes as its own 60-sample segment: the [140, 340)
      // neighbor is too far left to absorb within one target width.
      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 410,
          bakeableSamples: 400,
        ),
        isTrue,
      );
      expect(h.bakes.single, (
        start: 340,
        end: 400,
        texW: 60,
        onFrameCanvas: false,
      ));
    });
  });

  group('SegmentedGraphCache staleness quiescence', () {
    // These tests pin one no-progress loop shape each that the staleness
    // guards (SegmentedGraphCache._isStale / ._refreshEnd) exist to kill:
    // assert the cache converges, then stays converged (bake pump idle).
    void expectQuiescent({
      required double viewStart,
      required double viewSpan,
      required int totalSamples,
      double gw = 400,
    }) {
      for (int i = 0; i < 2; i++) {
        expect(
          h.paint(
            viewStart: viewStart,
            viewSpan: viewSpan,
            totalSamples: totalSamples,
            gw: gw,
          ),
          isFalse,
        );
        expect(h.calls, isEmpty);
      }
    }

    test('a pass-1 swallow bake (tile born past one target) goes '
        'quiescent', () {
      h.paint(viewStart: 0, viewSpan: 600, gw: 600, totalSamples: 200);
      // The gap bake swallows its 30 px remainder: [200, 430) is born at
      // target + 30 px. A width-threshold stale predicate would re-bake
      // this range forever; the progress guards leave it alone.
      h.paint(viewStart: 0, viewSpan: 600, gw: 600, totalSamples: 430);
      expect(h.bakes.single, (
        start: 200,
        end: 430,
        texW: 230,
        onFrameCanvas: false,
      ));

      expectQuiescent(viewStart: 0, viewSpan: 600, totalSamples: 430, gw: 600);
    });

    test('rounding-oversized full-target tiles never re-trigger; a narrow '
        'tile with a right neighbor extends to exactly one target span', () {
      // gw 650 / span 100 => pps 6.5 => targetSpan rounds to 31 samples,
      // i.e. full-target tiles are born at 201.5 px, slightly PAST the
      // nominal target. Their clamp leftover is exactly zero samples, so
      // no stale predicate may fire on them.
      h.paint(viewStart: 0, viewSpan: 100, gw: 650, totalSamples: 100);
      expect(h.bakes.single, (
        start: 69,
        end: 100,
        texW: 202,
        onFrameCanvas: false,
      ));
      h.paint(viewStart: 0, viewSpan: 100, gw: 650, totalSamples: 100);
      expect(h.bakes.single, (
        start: 38,
        end: 69,
        texW: 202,
        onFrameCanvas: false,
      ));
      h.paint(viewStart: 0, viewSpan: 100, gw: 650, totalSamples: 100);
      expect(h.bakes.single, (
        start: 7,
        end: 38,
        texW: 202,
        onFrameCanvas: false,
      ));
      // The [0, 7) gap (45.5 px) still crosses the bake threshold.
      h.paint(viewStart: 0, viewSpan: 100, gw: 650, totalSamples: 100);
      expect(h.bakes.single, (
        start: 0,
        end: 7,
        texW: 46,
        onFrameCanvas: false,
      ));
      // [0, 7) is meaningfully narrow (45.5 px < target/2) with a right
      // neighbor: it extends to exactly one target span (31 samples),
      // leaving the partially overlapped [7, 38) in place.
      h.paint(viewStart: 0, viewSpan: 100, gw: 650, totalSamples: 100);
      expect(h.bakes.single, (
        start: 0,
        end: 31,
        texW: 202,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, isEmpty);

      expectQuiescent(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 650);
    });

    test('a sub-0.5-target tile ending exactly at the bake horizon stays '
        'put (nothing to its right to claim)', () {
      // [0, 7) is 45.5 px wide and ends at the horizon: extending it is
      // impossible, so no amount of arrival-free frames may re-bake it.
      h.paint(viewStart: 0, viewSpan: 100, gw: 650, totalSamples: 7);
      expect(h.bakes.single, (
        start: 0,
        end: 7,
        texW: 46,
        onFrameCanvas: false,
      ));

      expectQuiescent(viewStart: 0, viewSpan: 100, totalSamples: 7, gw: 650);
    });

    test('a sub-0.5-target tile with a right neighbor extends to exactly '
        'one target span, then quiesces', () {
      h.paint(viewStart: 0, viewSpan: 600, gw: 600, totalSamples: 150);
      // The data jump leaves a 60 px sliver next to the coverage when the
      // gap fills right-aligned.
      h.paint(viewStart: 0, viewSpan: 600, gw: 600, totalSamples: 410);
      expect(h.bakes.single, (
        start: 210,
        end: 410,
        texW: 200,
        onFrameCanvas: false,
      ));
      // The 60-sample sliver crosses the gap threshold and bakes as its
      // own narrow segment; the live-edge absorb is capped at one target
      // width, so it cannot merge with [0, 150).
      h.paint(viewStart: 0, viewSpan: 600, gw: 600, totalSamples: 410);
      expect(h.bakes.single, (
        start: 150,
        end: 210,
        texW: 60,
        onFrameCanvas: false,
      ));
      // 60 px < target/2 with room to its right: extend to exactly one
      // target span, leaving the partially overlapped [210, 410) neighbor
      // in place.
      h.paint(viewStart: 0, viewSpan: 600, gw: 600, totalSamples: 410);
      expect(h.bakes.single, (
        start: 150,
        end: 350,
        texW: 200,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, isEmpty);

      expectQuiescent(viewStart: 0, viewSpan: 600, totalSamples: 410, gw: 600);
    });

    test('a stretched (sub-2-target) tile refreshes in place: one bake '
        'each, never a gap draw', () {
      // gw 400 => pps 4, 50-sample tiles. Growing gw to 760 stretches each
      // tile to 380 px (~1.9 targets): drift-stale, but under the split
      // threshold, so each re-bakes over its own range and coverage never
      // breaks.
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100);
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100);

      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 760);
      expect(h.bakes.single, (
        start: 50,
        end: 100,
        texW: 380,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, isEmpty);

      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 760);
      expect(h.bakes.single, (
        start: 0,
        end: 50,
        texW: 380,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, isEmpty);

      expectQuiescent(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 760);
    });

    test('a past-2-target tile splits: clamp bake, gap refill, narrow '
        'consolidation', () {
      // One tile [0, 100) at 200 px (gw 200, pps 2, 100-sample target
      // span). gw 450 (pps 4.5, 44-sample target span) stretches it to
      // 450 px: the refresh clamps to one target span and the remainder
      // refills as a gap over the following frames.
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 200);
      expectQuiescent(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 200);

      // Frame 1: clamp [0, 44), and the [44, 100) remainder vector-draws.
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 450);
      expect(h.bakes.single, (
        start: 0,
        end: 44,
        texW: 198,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws.single, (
        start: 44,
        end: 100,
        texW: 252,
        onFrameCanvas: true,
      ));

      // Frame 2: the 252 px gap refills right-aligned at one target span;
      // its 54 px left remainder exceeds the swallow threshold.
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 450);
      expect(h.bakes.single, (
        start: 56,
        end: 100,
        texW: 198,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws.single, (
        start: 44,
        end: 56,
        texW: 54,
        onFrameCanvas: true,
      ));

      // Frame 3: the 54 px remainder crosses the gap threshold.
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 450);
      expect(h.bakes.single, (
        start: 44,
        end: 56,
        texW: 54,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, isEmpty);

      // Frame 4: the 54 px strip is narrow with room to its right; it
      // extends to one target span, partially overlapping [56, 100)
      // (left-wins clip at blit time).
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 450);
      expect(h.bakes.single, (
        start: 44,
        end: 88,
        texW: 198,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, isEmpty);

      expectQuiescent(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 450);
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
          // layer's bake horizon (totalSamples - 2 * blockSize) must cover
          // the renderer's real need.
          expect(j - end, lessThanOrEqualTo(2 * bs), reason: 'end=$end bs=$bs');
          // ...and it must exceed one block size, or the join block is
          // truncated (the seam-step regression).
          expect(j - end, greaterThan(bs), reason: 'end=$end bs=$bs');
        }
      }
    });
  });
}
