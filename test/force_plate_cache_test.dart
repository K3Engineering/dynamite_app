import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/graph/force_plate_cache.dart';

/// A [ForcePlateDotRenderer] that records every invocation. Bake renders and
/// frame vector draws are distinguished by canvas identity: bakes happen on
/// the cache's internal recording canvas, head/tail/refill draws on the frame
/// canvas we pass to [ForcePlateCache.paint].
typedef RenderCall = ({int start, int end, bool onFrameCanvas});

class _Harness {
  final cache = ForcePlateCache<int>();
  final calls = <RenderCall>[];

  /// Run one [ForcePlateCache.paint] frame. The marker payload is the
  /// range's last sample index (end - 1), so composed markers identify
  /// exactly which range produced them. [liveTailVoid] makes ranges at or
  /// past [voidFrom] report no valid sample, which exercises the marker
  /// fallback to older ranges/buckets.
  ForcePlateTrail<int> paint({
    required int viewStart,
    required int viewEnd,
    required int totalSamples,
    int oldestSample = 0,
    double side = 300,
    double dpr = 1,
    int generation = 0,
    List<Object?> configKey = const ['cfg'],
    int voidFrom = 1 << 30,
  }) {
    calls.clear();
    final recorder = ui.PictureRecorder();
    final frameCanvas = Canvas(recorder);
    final trail = cache.paint(frameCanvas, (
      generation: generation,
      configKey: configKey,
      side: side,
      dpr: dpr,
      viewStart: viewStart,
      viewEnd: viewEnd,
      oldestSample: oldestSample,
      totalSamples: totalSamples,
      render: (canvas, start, end) {
        calls.add((
          start: start,
          end: end,
          onFrameCanvas: identical(canvas, frameCanvas),
        ));
        return start >= voidFrom ? null : end - 1;
      },
    ));
    recorder.endRecording().dispose();
    return trail;
  }

  List<RenderCall> get bakes => calls.where((c) => !c.onFrameCanvas).toList();
  List<RenderCall> get frameDraws =>
      calls.where((c) => c.onFrameCanvas).toList();

  void dispose() => cache.dispose();
}

void main() {
  late _Harness h;

  setUp(() => h = _Harness());
  tearDown(() => h.dispose());

  group('ForcePlateCache bootstrap fill', () {
    test('spends one bake per frame, rightmost first; edges draw vector', () {
      // 9000 samples = two full buckets [0, 4096) [4096, 8192) plus a
      // 808-sample live tail. Total < 2 * span: bucket at 8192 is partial
      // and live -- never baked.
      var trail = h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 4096, end: 8192, onFrameCanvas: false)]);
      // The still-unbaked middle bucket and the live tail vector-draw.
      expect(h.frameDraws, [
        (start: 0, end: 4096, onFrameCanvas: true),
        (start: 8192, end: 9000, onFrameCanvas: true),
      ]);
      expect(trail.marker, 8999);

      trail = h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 0, end: 4096, onFrameCanvas: false)]);
      // Both middles blit now (no render calls); the tail always draws.
      expect(h.frameDraws, [(start: 8192, end: 9000, onFrameCanvas: true)]);

      trail = h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      expect(trail.workRemains, isFalse);
      expect(h.bakes, isEmpty);
      expect(h.frameDraws, [(start: 8192, end: 9000, onFrameCanvas: true)]);
      expect(h.cache.bucketCount, 2);
    });

    test('the live bucket bakes once its full range exists', () {
      h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      expect(h.cache.bucketCount, 2);

      // Streaming past 12288 completes bucket 8192: baked next frame.
      final trail = h.paint(viewStart: 0, viewEnd: 12300, totalSamples: 12300);
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 8192, end: 12288, onFrameCanvas: false)]);
      expect(h.frameDraws, [(start: 12288, end: 12300, onFrameCanvas: true)]);
    });
  });

  group('ForcePlateCache window edges', () {
    test('a mid-bucket window start draws a vector head every frame', () {
      // Two bakes to steady state: the right middle bucket, then the head's
      // bucket (baked though only partially covered -- ready to blit when a
      // pan reveals its range).
      h.paint(viewStart: 1000, viewEnd: 9000, totalSamples: 9000);
      h.paint(viewStart: 1000, viewEnd: 9000, totalSamples: 9000);
      final trail = h.paint(viewStart: 1000, viewEnd: 9000, totalSamples: 9000);
      expect(trail.workRemains, isFalse);
      expect(h.frameDraws, [
        (start: 1000, end: 4096, onFrameCanvas: true), // head
        (start: 8192, end: 9000, onFrameCanvas: true), // tail
      ]);
      expect(trail.marker, 8999);
    });

    test('a window inside one bucket is all head', () {
      // The containing bucket bakes (fully formed, in view) even though the
      // tiny window never blits it; the window itself draws all-head.
      final trail = h.paint(viewStart: 100, viewEnd: 500, totalSamples: 9000);
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 0, end: 4096, onFrameCanvas: false)]);
      expect(h.frameDraws, [(start: 100, end: 500, onFrameCanvas: true)]);
      expect(trail.marker, 499);
      expect(
        h.paint(viewStart: 100, viewEnd: 500, totalSamples: 9000).workRemains,
        isFalse,
      );
    });

    test('a window past the data does nothing', () {
      final trail = h.paint(viewStart: -100, viewEnd: -50, totalSamples: 9000);
      expect((trail.marker, trail.workRemains), (null, false));
      expect(h.calls, isEmpty);
    });
  });

  group('ForcePlateCache marker fallback', () {
    test('a void live tail falls back to the newest baked middle bucket', () {
      h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000); // bakes 4096
      h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000); // bakes 0
      final trail = h.paint(
        viewStart: 0,
        viewEnd: 9000,
        totalSamples: 9000,
        voidFrom: 8192, // no valid dots in the live tail
      );
      // Marker from bucket 4096's bake-time record (end - 1 = 8191).
      expect(trail.marker, 8191);
      expect(h.frameDraws, [(start: 8192, end: 9000, onFrameCanvas: true)]);
    });
  });

  group('ForcePlateCache config invalidation', () {
    void fill() {
      h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      expect(
        h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000).workRemains,
        isFalse,
      );
    }

    test('a configKey change clears and rebuilds', () {
      fill();
      expect(h.cache.bucketCount, 2);
      final trail = h.paint(
        viewStart: 0,
        viewEnd: 9000,
        totalSamples: 9000,
        configKey: const ['other'],
      );
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 4096, end: 8192, onFrameCanvas: false)]);
      // The unbaked middle vector-draws during the rebuild (the smear).
      expect(h.frameDraws, [
        (start: 0, end: 4096, onFrameCanvas: true),
        (start: 8192, end: 9000, onFrameCanvas: true),
      ]);
    });

    test('a generation change clears', () {
      fill();
      expect(h.cache.bucketCount, 2);
      h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000, generation: 1);
      expect(h.cache.bucketCount, 1); // cleared, one rebake this frame
    });
  });

  group('ForcePlateCache retention and eviction', () {
    test('buckets under the ring read finger are never baked', () {
      // oldestSample 100: bucket 0 is partially dropped; only 4096 bakes.
      var trail = h.paint(
        viewStart: 100,
        viewEnd: 9000,
        totalSamples: 9000,
        oldestSample: 100,
      );
      expect(h.bakes, [(start: 4096, end: 8192, onFrameCanvas: false)]);
      trail = h.paint(
        viewStart: 100,
        viewEnd: 9000,
        totalSamples: 9000,
        oldestSample: 100,
      );
      expect(trail.workRemains, isFalse);
      expect(h.bakes, isEmpty);
      // The partially-dropped bucket's remainder is a per-frame head.
      expect(h.frameDraws.first, (start: 100, end: 4096, onFrameCanvas: true));
      expect(h.cache.bucketCount, 1);
    });

    test('buckets far outside the window are evicted', () {
      h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      expect(h.cache.bucketCount, 2);
      // Jump far ahead: both old buckets are past the eviction margin. The
      // head bucket overlapping the new window ([196608, 200704)) bakes, so
      // it is ready to blit when a pan reveals more of it.
      final trail = h.paint(
        viewStart: 200000,
        viewEnd: 201000,
        totalSamples: 201000,
      );
      expect(h.bakes, [(start: 196608, end: 200704, onFrameCanvas: false)]);
      expect(h.cache.bucketCount, 1);
      expect(trail.marker, 200999);
    });
  });
}
