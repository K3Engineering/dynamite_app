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
    double hPad = kSegmentImagePad,
    double vPad = kSegmentImagePad,

    /// Width the renderer reports, as a fraction of [texW]. Production's
    /// renderers return a fractional width (samples * px-per-sample), which the
    /// texture size rounds up, leaving a dead column.
    double renderWidthScale = 1.0,
  }) {
    calls.clear();
    final recorder = ui.PictureRecorder();
    final frameCanvas = Canvas(recorder);
    final result = cache.paint(frameCanvas, (
      config: (
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
        hPad: hPad,
        vPad: vPad,
      ),
      render: (Canvas canvas, int start, int end, int texW) {
        calls.add((
          start: start,
          end: end,
          texW: texW,
          onFrameCanvas: identical(canvas, frameCanvas),
        ));
        return texW * renderWidthScale;
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

    test('a refresh swallowing a right neighbor past a RECEDED horizon '
        'clamps to the horizon', () {
      // pps 12.5, target span 16 throughout. Build the magic pair:
      // A=[10, 16)@y100 (y-drift-stale vs the end state) abutting
      // B=[16, 32)@y130 (fresh), with B's tail past a receded horizon.
      h.paint(viewStart: 0, viewSpan: 32, totalSamples: 32, yMax: 100);
      h.paint(viewStart: 0, viewSpan: 32, totalSamples: 32, yMax: 100);
      // Window [10, 42), horizon receded to 26: the sweep clamps [16, 32)
      // to [16, 26) ...
      h.paint(
        viewStart: 10,
        viewSpan: 32,
        totalSamples: 32,
        bakeableSamples: 26,
        remapKey: const ['k2'],
        yMax: 100,
      );
      expect(h.bakes.single, (
        start: 16,
        end: 26,
        texW: 125,
        onFrameCanvas: false,
      ));
      // ... then [0, 16) to [10, 16) -- the future stale tile A.
      h.paint(
        viewStart: 10,
        viewSpan: 32,
        totalSamples: 32,
        bakeableSamples: 26,
        remapKey: const ['k2'],
        yMax: 100,
      );
      expect(h.bakes.single, (
        start: 10,
        end: 16,
        texW: 75,
        onFrameCanvas: false,
      ));
      // Horizon back at 32, fold now spans to 130: the [26, 32) gap bake
      // absorbs [16, 26) into B=[16, 32) FRESH under the new range.
      h.paint(
        viewStart: 10,
        viewSpan: 32,
        totalSamples: 32,
        bakeableSamples: 32,
        remapKey: const ['k2'],
        yMax: 130,
      );
      expect(h.bakes.single, (
        start: 16,
        end: 32,
        texW: 200,
        onFrameCanvas: false,
      ));
      // Horizon receded to 26 again. B stays untouched (not stale; its
      // empty plan reads as identity), A is y-drift-stale (100 vs 130) and
      // narrow (75 px), so its refresh swallows B -- whose end is past the
      // receded horizon. Pre-fix this baked [10, 32); the clamp caps it at
      // 26, and B's [26, 32) tail becomes a horizon-zone vector draw.
      expect(
        h.paint(
          viewStart: 10,
          viewSpan: 32,
          totalSamples: 32,
          bakeableSamples: 26,
          remapKey: const ['k2'],
          yMax: 130,
        ),
        isTrue,
      );
      expect(h.bakes.single, (
        start: 10,
        end: 26,
        texW: 200,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws.single, (
        start: 26,
        end: 32,
        texW: 75,
        onFrameCanvas: true,
      ));
    });

    test('a stale segment the receded horizon fully overtakes stops blitting '
        'and vector-draws instead', () {
      // Two 50-sample tiles at 4 px/sample: [0,50) and [50,100), baked under
      // yMax 100. Then the horizon recedes to 50 AND the fold widens to 140,
      // so [50,100) is y-drift-stale with no sample left at or below the
      // horizon. The sweep could only drop it, so prepareFrame must: leaving
      // it blits frozen pixels under the old fold forever.
      for (var i = 0; i < 3; i++) {
        h.paint(viewStart: 0, viewSpan: 100, totalSamples: 200, yMax: 100);
      }
      expect(h.cache.debugLastRaster!.blits, hasLength(2));

      h.paint(
        viewStart: 0,
        viewSpan: 100,
        totalSamples: 200,
        bakeableSamples: 50,
        yMax: 140,
      );
      // [0,50) is refreshable and wins the sweep; [50,100) is retired, and
      // its range vector-draws as a gap.
      expect(h.bakes.single.start, 0);
      expect(h.bakes.single.end, 50);
      final raster = h.cache.debugLastRaster!;
      expect(raster.blits.map((b) => b.seg.start), isNot(contains(50)));
      expect(raster.gaps.single.start, 50);
      expect(raster.gaps.single.end, 100);
    });
  });

  group('SegmentedGraphCache fold window', () {
    // The Y-range is folded from the visible window only, so a bake covering
    // out-of-window samples raster-clips them at the texture top and freezes
    // the cut into the tile (file header invariant). These tests force each
    // bake path that historically escaped the window (re-bake of a
    // view-straddling tile, left-neighbor absorb in a gap bake) and assert
    // the bake stays inside it.
    test('a refresh of a left-straddling tile re-bakes only the in-window '
        'part, dropping the out-of-fold fringe', () {
      // Two tiles cover [0, 400); the window slides right so [0, 200)
      // straddles the left edge, then a remapKey bump sweeps all tiles.
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      // Frame 1: the [400, 500) exposure bakes first (gap priority).
      expect(
        h.paint(
          viewStart: 100,
          viewSpan: 400,
          totalSamples: 500,
          remapKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes.single, (
        start: 400,
        end: 500,
        texW: 100,
        onFrameCanvas: false,
      ));
      // Frame 2: the sweep reaches the stale [200, 400), entirely in-window.
      expect(
        h.paint(
          viewStart: 100,
          viewSpan: 400,
          totalSamples: 500,
          remapKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes.single, (
        start: 200,
        end: 400,
        texW: 200,
        onFrameCanvas: false,
      ));
      // Frame 3: the straddling [0, 200) is refreshed clamped to the window
      // -- NOT re-baked in full as [0, 200), which would clip its left half
      // above the fold. The [0, 100) fringe becomes an out-of-view gap.
      expect(
        h.paint(
          viewStart: 100,
          viewSpan: 400,
          totalSamples: 500,
          remapKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes.single, (
        start: 100,
        end: 200,
        texW: 100,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, isEmpty);

      // Converged: nothing stale, no fringe work churns on.
      expect(
        h.paint(
          viewStart: 100,
          viewSpan: 400,
          totalSamples: 500,
          remapKey: const ['other'],
        ),
        isFalse,
      );
      expect(h.calls, isEmpty);
    });

    test('a gap bake absorbing a left-straddling neighbor bakes from the '
        'window edge, not the neighbor start', () {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 200); // tile [0,200)
      // Zoomed-out window [50, 1050): pps = 0.4, targetSpan = 500. The
      // [200, 400) gap abuts the straddling tile; absorbing it keeps the
      // merged bake within one target (160 px), so pre-fix this baked
      // [0, 400). The clamp drops the [0, 50) fringe to an out-of-view gap.
      expect(h.paint(viewStart: 50, viewSpan: 1000, totalSamples: 400), isTrue);
      expect(h.bakes.single, (
        start: 50,
        end: 400,
        texW: 140,
        onFrameCanvas: false,
      ));
      // [50, 400) is fully covered; nothing vector-draws.
      expect(h.gapDraws, isEmpty);
    });

    test('a refresh of a right-straddling tile retracts its end to the '
        'window', () {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      // Panned window [50, 350) at pps = 4/3: [200, 400) straddles the
      // right edge. The config sweep refreshes it as [200, 350), dropping
      // the out-of-fold tail.
      expect(
        h.paint(
          viewStart: 50,
          viewSpan: 300,
          totalSamples: 400,
          remapKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes.single, (
        start: 200,
        end: 350,
        texW: 200,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, isEmpty);
    });
  });

  group('SegmentedGraphCache staleness quiescence', () {
    // These tests pin one no-progress loop shape each that the staleness
    // guards (SegmentedGraphCache._stalePlan / ._planRefresh) exist to
    // kill: assert the cache converges, then stays converged (bake pump
    // idle).
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
        'tile at the left edge merges with its right neighbor', () {
      // gw 650 / span 100 => pps 6.5 => targetSpan rounds to 31 samples,
      // i.e. full-target tiles are born at 201.5 px, slightly PAST the
      // nominal target. No stale predicate may fire on them.
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
      // [0, 7) is meaningfully narrow (45.5 px < target/2) with an abutting
      // right neighbor it cannot outgrow into: it swallows [7, 38) whole
      // (38 samples, 247 px <= 1.5 targets), keeping the cache disjoint.
      h.paint(viewStart: 0, viewSpan: 100, gw: 650, totalSamples: 100);
      expect(h.bakes.single, (
        start: 0,
        end: 38,
        texW: 247,
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

    test('a sub-0.5-target tile swallows its abutting left neighbor in one '
        'bake, then quiesces', () {
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
      // width, so it cannot merge with [0, 150) there.
      h.paint(viewStart: 0, viewSpan: 600, gw: 600, totalSamples: 410);
      expect(h.bakes.single, (
        start: 150,
        end: 210,
        texW: 60,
        onFrameCanvas: false,
      ));
      // 60 px < target/2: the refresh swallows the abutting [0, 150)
      // (210 samples, 210 px <= 1.5 targets) instead of extending [150,
      // 210)'s end over part of [210, 410) as an overlap.
      h.paint(viewStart: 0, viewSpan: 600, gw: 600, totalSamples: 410);
      expect(h.bakes.single, (
        start: 0,
        end: 210,
        texW: 210,
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

    test('a past-2-target tile splits right-anchored: the remainder refills '
        'as gaps marching left, then merges its left-cap sliver', () {
      // One tile [0, 100) at 200 px (gw 200, pps 2, 100-sample target
      // span). gw 450 (pps 4.5, 44-sample target span) stretches it to
      // 450 px: the refresh bakes the RIGHTMOST target span.
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 200);
      expectQuiescent(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 200);

      // Frame 1: split [56, 100) (44 samples, 198 px); the [0, 56)
      // remainder vector-draws.
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 450);
      expect(h.bakes.single, (
        start: 56,
        end: 100,
        texW: 198,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws.single, (
        start: 0,
        end: 56,
        texW: 252,
        onFrameCanvas: true,
      ));

      // Frame 2: the 252 px gap refills right-aligned at one target span;
      // its 54 px left remainder exceeds the swallow threshold.
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 450);
      expect(h.bakes.single, (
        start: 12,
        end: 56,
        texW: 198,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws.single, (
        start: 0,
        end: 12,
        texW: 54,
        onFrameCanvas: true,
      ));

      // Frame 3: the 54 px remainder crosses the gap threshold.
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 450);
      expect(h.bakes.single, (
        start: 0,
        end: 12,
        texW: 54,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, isEmpty);

      // Frame 4: the 54 px strip [0, 12) is narrow with no left neighbor
      // and no uncovered room: it swallows [12, 56) whole (56 samples,
      // 252 px <= 1.5 targets).
      h.paint(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 450);
      expect(h.bakes.single, (
        start: 0,
        end: 56,
        texW: 252,
        onFrameCanvas: false,
      ));
      expect(h.gapDraws, isEmpty);

      expectQuiescent(viewStart: 0, viewSpan: 100, totalSamples: 100, gw: 450);
    });
  });

  group('SegmentedGraphCache zoom sweep consolidation', () {
    test('zoom-out: narrow-tile era collapses into 1.5-target tiles at '
        '~3 tiles per bake, rightmost-first', () {
      // 1000 samples at gw 1000 (pps 1) fill as five 200-sample tiles.
      for (int i = 0; i < 5; i++) {
        expect(
          h.paint(viewStart: 0, viewSpan: 1000, gw: 1000, totalSamples: 1000),
          isTrue,
        );
      }
      expect(
        h.paint(viewStart: 0, viewSpan: 1000, gw: 1000, totalSamples: 1000),
        isFalse,
      );

      // Zoom out to span 2500 (pps 0.4, 500-sample target span): the old
      // tiles shrink to 80 px each. The exposed range refills first (gap
      // priority, right-aligned)...
      const view = (
        viewStart: 0.0,
        viewSpan: 2500.0,
        gw: 1000.0,
        totalSamples: 2500,
      );
      h.paint(
        viewStart: view.viewStart,
        viewSpan: view.viewSpan,
        gw: view.gw,
        totalSamples: view.totalSamples,
      );
      expect(h.bakes, [
        (start: 2000, end: 2500, texW: 200, onFrameCanvas: false),
      ]);
      h.paint(
        viewStart: view.viewStart,
        viewSpan: view.viewSpan,
        gw: view.gw,
        totalSamples: view.totalSamples,
      );
      expect(h.bakes, [
        (start: 1500, end: 2000, texW: 200, onFrameCanvas: false),
      ]);
      h.paint(
        viewStart: view.viewStart,
        viewSpan: view.viewSpan,
        gw: view.gw,
        totalSamples: view.totalSamples,
      );
      expect(h.bakes, [
        (start: 1000, end: 1500, texW: 200, onFrameCanvas: false),
      ]);

      // ...then the sweep consolidates the five 80 px tiles in two bakes:
      // rightmost-first, each swallowing abutting left neighbors up to 1.5
      // targets (3 tiles / 240 px, then 2 tiles / 160 px). No tile is
      // rebaked twice; the pre-simplification overlap debris (each tile
      // extending targetSpan over its already-fresh neighbor) cannot form.
      h.paint(
        viewStart: view.viewStart,
        viewSpan: view.viewSpan,
        gw: view.gw,
        totalSamples: view.totalSamples,
      );
      expect(h.bakes, [
        (start: 400, end: 1000, texW: 240, onFrameCanvas: false),
      ]);
      h.paint(
        viewStart: view.viewStart,
        viewSpan: view.viewSpan,
        gw: view.gw,
        totalSamples: view.totalSamples,
      );
      expect(h.bakes, [(start: 0, end: 400, texW: 160, onFrameCanvas: false)]);

      for (int i = 0; i < 2; i++) {
        expect(
          h.paint(
            viewStart: view.viewStart,
            viewSpan: view.viewSpan,
            gw: view.gw,
            totalSamples: view.totalSamples,
          ),
          isFalse,
        );
        expect(h.calls, isEmpty);
      }
    });
  });

  group('SegmentedGraphCache dpr 2 geometry', () {
    test('the bootstrap bake/blit flow is dpr-invariant in logical px', () {
      // The identity flow from the bootstrap group at dpr 2: segment
      // bookkeeping is entirely in logical px / samples, so the same
      // bake/gap-draw sequence must result (only the rasterized textures'
      // physical size doubles, which the harness cannot see).
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, dpr: 2.0),
        isTrue,
      );
      expect(h.bakes, [
        (start: 200, end: 400, texW: 200, onFrameCanvas: false),
      ]);
      expect(h.gapDraws, [
        (start: 0, end: 200, texW: 200, onFrameCanvas: true),
      ]);

      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, dpr: 2.0),
        isTrue,
      );
      expect(h.bakes, [(start: 0, end: 200, texW: 200, onFrameCanvas: false)]);
      expect(h.gapDraws, isEmpty);

      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, dpr: 2.0),
        isFalse,
      );
      expect(h.calls, isEmpty);
    });
  });

  group('SegmentedGraphCache blit geometry', () {
    // Blits are invisible to a render-call recorder: they are drawImageRect
    // calls, not render callbacks. debugLastRaster records the Rect operands
    // _drawBlits actually passed to the canvas, so these see the shell as well
    // as the core: a swapped dx/dy or clipL/clipR fails here.
    test('the two pads are not interchangeable: hPad widens x and the source '
        'rect, vPad widens y and the clip', () {
      // Production passes a LARGER hPad for the graphs' one-block polyline
      // join overshoot (blockPx + 2) while vPad stays at the base pad. Every
      // other test uses one constant for both, so swapping them in the blit
      // (or in the bake size) would survive all of them.
      const hPad = 40.0; // a zoomed-in block's overshoot
      const vPad = 4.0;
      for (var i = 0; i < 3; i++) {
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          hPad: hPad,
          vPad: vPad,
        );
      }

      final b = h.cache.debugLastRaster!.blits.first;
      // Identity mapping: content 200 px, x-scale 1.
      expect(b.dst.left, closeTo(b.seg.start - hPad, 0.001));
      expect(b.dst.width, closeTo(b.seg.contentW + 2 * hPad, 0.001));
      expect(b.src.width, closeTo(b.seg.contentW + 2 * hPad, 0.001));
      expect(b.dst.top, closeTo(-vPad, 0.001));
      expect(b.dst.height, closeTo(100 + 2 * vPad, 0.001));
      expect(b.src.height, closeTo(100 + 2 * vPad, 0.001));
      // The vertical clip band is the pad, not the horizontal one.
      expect(b.clip.top, closeTo(-vPad, 0.001));
      expect(b.clip.bottom, closeTo(100 + vPad, 0.001));
    });

    test('a fully covered view blits each segment at its window x, with the '
        'correct vertical scale and clip', () {
      // Two 200-sample tiles at 1 px/sample, gh 100, y-range 0..100 baked
      // and blitted under an identity mapping.
      for (var i = 0; i < 3; i++) {
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      }

      final raster = h.cache.debugLastRaster!;
      expect(raster.blits, hasLength(2));

      for (final b in raster.blits) {
        // Identity mapping: content width == sample span, so the x-scale is
        // 1 and the destination is the segment's own window span plus pads.
        const xs = 1.0;
        expect(b.seg.contentW, closeTo(200, 0.001));
        expect(
          b.dst.left,
          closeTo(b.seg.start * 1.0 - kSegmentImagePad * xs, 0.001),
        );
        expect(
          b.dst.width,
          closeTo((b.seg.contentW + 2 * kSegmentImagePad) * xs, 0.001),
        );
        // Identity in y too: an unbaked-value drift of zero means the
        // vertical scale is 1, so the destination height is the plot plus
        // pads, and the top content row sits at y = 0.
        expect(b.dst.height, closeTo(100 + 2 * kSegmentImagePad, 0.001));
        expect(b.dst.top, closeTo(-kSegmentImagePad, 0.001));
        // Clip is the view bounds, never outside it.
        expect(b.clip.left, greaterThanOrEqualTo(0));
        expect(b.clip.right, lessThanOrEqualTo(400));
        expect(b.clip.left, lessThan(b.clip.right));
        expect(b.clip.top, lessThan(b.clip.bottom));
        // Source rect is the CONTENT box in physical px, not the ceil'd
        // image bounds.
        expect(
          b.src.width,
          closeTo((b.seg.contentW + 2 * kSegmentImagePad), 0.001),
        );
        expect(b.src.height, closeTo(100 + 2 * kSegmentImagePad, 0.001));
        expect(b.src.left, 0);
        expect(b.src.top, 0);
      }
    });

    test('a vertical stretch scales dy/dh and leaves dx/dw alone', () {
      for (var i = 0; i < 3; i++) {
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      }
      final base = h.cache.debugLastRaster!.blits.first;

      // Halve the Y range with no re-bake: every tile is now a 2x vertical
      // stretch, so it must blit twice as tall. Its top content row (the
      // baked yMax, 100) now sits a full plot height ABOVE the view, so dy is
      // driven by that offset, not by scaling the baked dy.
      h.paint(
        viewStart: 0,
        viewSpan: 400,
        totalSamples: 400,
        yMax: 50,
        bakeableSamples: 400,
      );
      final stretched = h.cache.debugLastRaster!.blits.firstWhere(
        (b) => b.seg.start == base.seg.start,
      );
      expect(stretched.dst.height, closeTo(base.dst.height * 2, 0.01));
      expect(stretched.dst.top, closeTo(-100 - kSegmentImagePad * 2, 0.01));
      expect(stretched.dst.left, closeTo(base.dst.left, 0.001));
      expect(stretched.dst.width, closeTo(base.dst.width, 0.001));
    });

    test('the blit pads scale with the content, and the source rect is in '
        'physical px', () {
      const hPad = 40.0;
      const vPad = 4.0;
      const dpr = 2.0;
      // Bake at dpr 2 (texture in physical px) under an identity mapping, so
      // the dest rect is logical px and the source rect is not.
      for (var i = 0; i < 3; i++) {
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          hPad: hPad,
          vPad: vPad,
          dpr: dpr,
        );
      }
      final base = h.cache.debugLastRaster!.blits.first;
      final contentW = base.seg.contentW;
      // Dropping `* dpr` here would silently halve the sampled region on every
      // retina device.
      expect(base.src.width, closeTo((contentW + 2 * hPad) * dpr, 0.001));
      expect(base.src.height, closeTo((100 + 2 * vPad) * dpr, 0.001));
      expect(base.dst.width, closeTo(contentW + 2 * hPad, 0.001));
      expect(base.dst.height, closeTo(100 + 2 * vPad, 0.001));

      // Widen the x-axis only: xs = 400/410, ys = 1. Both pad offsets must
      // ride xs; a pad added unscaled would be off by hPad*(1-xs) px.
      h.paint(
        viewStart: 0,
        viewSpan: 410,
        totalSamples: 400,
        hPad: hPad,
        vPad: vPad,
        dpr: dpr,
      );
      final scaled = h.cache.debugLastRaster!.blits.firstWhere(
        (b) => b.seg.start == base.seg.start,
      );
      const xs = 400 / 410;
      expect(scaled.dst.width, closeTo((contentW + 2 * hPad) * xs, 0.01));
      expect(scaled.dst.left, closeTo(base.seg.start * xs - hPad * xs, 0.01));
      expect(scaled.dst.height, closeTo(base.dst.height, 0.001));
      expect(scaled.dst.top, closeTo(base.dst.top, 0.001));
    });

    test('a destructiveKey mismatch drops the segment from the blit list, not '
        'just from the render calls', () {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      expect(h.cache.debugLastRaster!.blits, hasLength(2));

      // Both tiles are now destructive-stale. The sweep re-bakes the
      // rightmost; the left must not blit at all this frame.
      h.paint(
        viewStart: 0,
        viewSpan: 400,
        totalSamples: 400,
        destructiveKey: const ['other'],
      );
      final raster = h.cache.debugLastRaster!;
      expect(
        raster.blits.map((b) => b.seg.start),
        isNot(contains(0)),
        reason: 'a destructive-stale segment must never be blitted',
      );
      // And nothing is vector-drawn in its place: suppressed means blank.
      expect(raster.gaps, isEmpty);
    });

    test('a suppressed segment leaves the blit list entirely', () {
      // Y-range collapse stretches the baked line past
      // kMaxBlitLineFraction, so the still-stale tiles must not blit: the
      // plot draws blank for them until the sweep re-bakes.
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      expect(h.cache.debugLastRaster!.blits, hasLength(2));

      // Frame 1: the sweep re-bakes the rightmost; the left is suppressed.
      h.paint(
        viewStart: 0,
        viewSpan: 400,
        totalSamples: 400,
        yMax: 5,
        remapKey: const ['other'],
      );
      final suppressed = h.cache.debugLastRaster!;
      expect(
        suppressed.blits.map((b) => b.seg.start),
        isNot(contains(0)),
        reason: 'a 20x stretched line must not smear across the plot',
      );
      expect(suppressed.gaps, isEmpty);
    });

    test('a gap blit lands at the uncovered range, not near it', () {
      // Cover [0, 200) first; then 20 samples arrive, forming a 20 px sliver
      // past the coverage -- under the 40 px bake threshold, so it
      // vector-draws at x = 200 instead of baking.
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 200);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 220);
      final gaps = h.cache.debugLastRaster!.gaps;
      expect(gaps, hasLength(1));
      expect(gaps.single.start, 200);
      expect(gaps.single.end, 220);
      expect(gaps.single.x, closeTo(200, 0.001));
      // The clip is exactly the visible gap, so the renderer cannot paint
      // outside its own range.
      expect(gaps.single.clip.left, closeTo(200, 0.001));
      expect(gaps.single.clip.right, closeTo(220, 0.001));
      expect(gaps.single.clip.top, closeTo(-kSegmentImagePad, 0.001));
      expect(gaps.single.clip.bottom, closeTo(100 + kSegmentImagePad, 0.001));
    });

    test('a gap straddling the left view edge is clipped, not moved', () {
      // A fractional window start puts the floored coverage start (and so the
      // gap's own x) up to one sample-pixel left of the plot. The translate
      // keeps the content mapping exact, so the CLIP is what gets clamped; a
      // clip that followed the translate would paint over the left edge.
      h.paint(
        viewStart: 205.5,
        viewSpan: 400,
        totalSamples: 420,
        bakeableSamples: 150,
      );
      final gap = h.cache.debugLastRaster!.gaps.single;
      expect(gap.start, 205);
      expect(gap.x, closeTo(-0.5, 0.001));
      expect(gap.clip.left, 0);
      // The right edge is the gap's own end (sample 420 -> x 214.5), not the
      // plot edge: the clip must not widen the range either.
      expect(gap.clip.right, closeTo(-0.5 + (gap.end - gap.start), 0.001));
      expect(gap.clip.right, lessThan(400));
    });

    test('the source rect is the content box, not the ceil-sized image', () {
      // A range whose rendered width is fractional leaves a dead column: the
      // texture is ceil(texW) px. Sampling the image bounds instead of the
      // content box bakes that scale error into every blit.
      for (var i = 0; i < 3; i++) {
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          renderWidthScale: 0.99,
        );
      }
      final b = h.cache.debugLastRaster!.blits.first;
      expect(b.seg.contentW, closeTo(198, 0.001));
      // Identity x mapping with scale 1/0.99: the source is the content box,
      // not the 200-column texture.
      expect(
        b.src.width,
        closeTo(b.seg.contentW + 2 * kSegmentImagePad, 0.0001),
      );
      expect(b.src.width, isNot(closeTo(200 + 2 * kSegmentImagePad, 0.01)));
    });
  });

  group('SegmentedGraphCache texture lifecycle', () {
    // The cache's only real state is the texture map, keyed by
    // SegmentMeta.textureId and reconciled against the segment list each frame.
    // These pin that a texture actually reaches dispose() on every drop path; a
    // leaked ui.Image is invisible to every other test.
    test('a generation reset disposes every texture', () {
      for (var i = 0; i < 3; i++) {
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      }
      expect(h.cache.debugTextures, hasLength(2));
      final old = h.cache.debugTextures.values.toList();

      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, generation: 1);
      for (final img in old) {
        expect(img.debugDisposed, isTrue);
      }
    });

    test('evicting a segment far outside the view disposes its texture', () {
      for (var i = 0; i < 3; i++) {
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 4000);
      }
      final evicted = h.cache.debugTextures.values.first;
      expect(h.cache.debugTextures.length, greaterThan(1));

      // Jump far past the eviction margin so nothing in view survives.
      h.paint(viewStart: 3600, viewSpan: 400, totalSamples: 4000);
      expect(evicted.debugDisposed, isTrue);
    });

    test('clear() disposes every texture and forgets the state', () {
      for (var i = 0; i < 3; i++) {
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      }
      final images = h.cache.debugTextures.values.toList();
      expect(images, isNotEmpty);

      h.cache.clear();
      for (final img in images) {
        expect(img.debugDisposed, isTrue);
      }
      expect(h.cache.debugTextures, isEmpty);
      // State is forgotten too: the next frame bootstraps from empty.
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isTrue);
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
