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
  /// bake target span equals kSegmentTargetPx samples (200).
  bool paint({
    required int viewStart,
    required int viewSpan,
    required int totalSamples,
    double gw = 400,
    double gh = 100,
    double dpr = 1.0,
    double yMin = 0,
    double yMax = 100,
    List<Object?> configKey = const ['k'],
    double maxDirectGapPx = double.infinity,
  }) {
    calls.clear();
    final recorder = ui.PictureRecorder();
    final frameCanvas = Canvas(recorder);
    final result = cache.paint(
      frameCanvas,
      configKey: configKey,
      gw: gw,
      gh: gh,
      dpr: dpr,
      viewStart: viewStart,
      viewSpan: viewSpan,
      yMin: yMin,
      yMax: yMax,
      totalSamples: totalSamples,
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
        return texW.toDouble();
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

  group('SegmentedGraphCache config invalidation', () {
    /// Cover the 400-sample view (two bakes) and verify steady state.
    void fill() {
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400);
      expect(h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400), isFalse);
    }

    test('a configKey change drops every segment', () {
      fill();
      expect(
        h.paint(
          viewStart: 0,
          viewSpan: 400,
          totalSamples: 400,
          configKey: const ['other'],
        ),
        isTrue,
      );
      expect(h.bakes.single.start, 0); // re-baking from scratch
    });

    test('a gh change drops every segment', () {
      fill();
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, gh: 120),
        isTrue,
      );
      expect(h.bakes.single.start, 0);
    });

    test('a dpr change drops every segment', () {
      fill();
      expect(
        h.paint(viewStart: 0, viewSpan: 400, totalSamples: 400, dpr: 2.0),
        isTrue,
      );
      expect(h.bakes.single.start, 0);
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
}
