import 'dart:ui' as ui;

import 'package:dynamite_app/widgets/graph/affine2.dart';
import 'package:dynamite_app/widgets/graph/affine_dot_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

typedef RenderCall = ({int start, int end, bool onFrameCanvas});

class _Harness {
  final cache = AffineDotCache<int>();
  final calls = <RenderCall>[];

  static const baseProjection = Affine2(
    xx: 0.01,
    xy: 0,
    yx: 0,
    yy: -1,
    tx: 0,
    ty: 100,
  );

  AffineDotTrail<int> paint({
    required int viewStart,
    required int viewEnd,
    required int totalSamples,
    int oldestSample = 0,
    Affine2 projection = baseProjection,
    double width = 300,
    double height = 200,
    double dpr = 1,
    int generation = 0,
    List<Object?> destructiveKey = const ['cfg'],
    int voidFrom = 1 << 30,
  }) {
    calls.clear();
    final recorder = ui.PictureRecorder();
    final frameCanvas = Canvas(recorder);
    final trail = cache.paint(frameCanvas, (
      generation: generation,
      destructiveKey: destructiveKey,
      width: width,
      height: height,
      dpr: dpr,
      projection: projection,
      viewStart: viewStart,
      viewEnd: viewEnd,
      oldestSample: oldestSample,
      totalSamples: totalSamples,
      render: (canvas, start, end, project) {
        calls.add((
          start: start,
          end: end,
          onFrameCanvas: identical(canvas, frameCanvas),
        ));
        // Exercise the supplied callback: unlike a captured projection, this
        // must be the current mapping on both bake and vector-render canvases.
        project(start.toDouble(), 0);
        return start >= voidFrom ? null : end - 1;
      },
    ));
    recorder.endRecording().dispose();
    return trail;
  }

  List<RenderCall> get bakes => calls.where((c) => !c.onFrameCanvas).toList();
  List<RenderCall> get frameDraws =>
      calls.where((c) => c.onFrameCanvas).toList();

  void fill({Affine2 projection = baseProjection}) {
    paint(
      viewStart: 0,
      viewEnd: 9000,
      totalSamples: 9000,
      projection: projection,
    );
    paint(
      viewStart: 0,
      viewEnd: 9000,
      totalSamples: 9000,
      projection: projection,
    );
    expect(cache.bucketCount, 2);
  }

  void dispose() => cache.dispose();
}

void main() {
  late _Harness h;

  setUp(() => h = _Harness());
  tearDown(() => h.dispose());

  group('bootstrap and stable reuse', () {
    test('bakes one full bucket per frame, rightmost first', () {
      var trail = h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 4096, end: 8192, onFrameCanvas: false)]);
      expect(h.frameDraws, [
        (start: 0, end: 4096, onFrameCanvas: true),
        (start: 8192, end: 9000, onFrameCanvas: true),
      ]);
      expect(trail.marker, 8999);

      trail = h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 0, end: 4096, onFrameCanvas: false)]);
      expect(h.frameDraws, [(start: 8192, end: 9000, onFrameCanvas: true)]);

      trail = h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      expect(trail.workRemains, isFalse);
      expect(h.bakes, isEmpty);
      expect(h.frameDraws, [(start: 8192, end: 9000, onFrameCanvas: true)]);
      expect(h.cache.bucketCount, 2);
    });

    test('a newly completed live bucket bakes on the next frame', () {
      h.fill();
      final trail = h.paint(viewStart: 0, viewEnd: 12300, totalSamples: 12300);
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 8192, end: 12288, onFrameCanvas: false)]);
      expect(h.frameDraws, [(start: 12288, end: 12300, onFrameCanvas: true)]);
    });
  });

  group('stale projection', () {
    const zoomedIn = Affine2(xx: 0.02, xy: 0, yx: 0, yy: -1, tx: 0, ty: 100);

    test('safe affine remap reuses a stale texture without vector redraw', () {
      h.fill();
      var trail = h.paint(
        viewStart: 0,
        viewEnd: 9000,
        totalSamples: 9000,
        projection: zoomedIn,
      );
      // The rightmost stale bucket rebakes immediately; bucket 0 is still old,
      // but its old image covers the narrower raw-space view and can remap.
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 4096, end: 8192, onFrameCanvas: false)]);
      expect(h.frameDraws, [(start: 8192, end: 9000, onFrameCanvas: true)]);

      trail = h.paint(
        viewStart: 0,
        viewEnd: 9000,
        totalSamples: 9000,
        projection: zoomedIn,
      );
      expect(h.bakes, [(start: 0, end: 4096, onFrameCanvas: false)]);
      expect(h.frameDraws, [(start: 8192, end: 9000, onFrameCanvas: true)]);
      expect(
        h
            .paint(
              viewStart: 0,
              viewEnd: 9000,
              totalSamples: 9000,
              projection: zoomedIn,
            )
            .workRemains,
        isFalse,
      );
    });

    test('unsafe expansion vector-draws until rolling rebake completes', () {
      h.fill(projection: zoomedIn);
      var trail = h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 4096, end: 8192, onFrameCanvas: false)]);
      expect(h.frameDraws, [
        (start: 0, end: 4096, onFrameCanvas: true),
        (start: 8192, end: 9000, onFrameCanvas: true),
      ]);

      trail = h.paint(viewStart: 0, viewEnd: 9000, totalSamples: 9000);
      expect(h.bakes, [(start: 0, end: 4096, onFrameCanvas: false)]);
      expect(h.frameDraws, [(start: 8192, end: 9000, onFrameCanvas: true)]);
      expect(trail.workRemains, isTrue);
    });

    test('DPR-only staleness can still use the affine texture path', () {
      h.fill();
      final trail = h.paint(
        viewStart: 0,
        viewEnd: 9000,
        totalSamples: 9000,
        dpr: 2,
      );
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 4096, end: 8192, onFrameCanvas: false)]);
      expect(h.frameDraws, [(start: 8192, end: 9000, onFrameCanvas: true)]);
    });
  });

  group('window edges and markers', () {
    test(
      'partial head and live tail stay vector; newest marker is composed',
      () {
        h.paint(viewStart: 1000, viewEnd: 9000, totalSamples: 9000);
        h.paint(viewStart: 1000, viewEnd: 9000, totalSamples: 9000);
        final trail = h.paint(
          viewStart: 1000,
          viewEnd: 9000,
          totalSamples: 9000,
        );
        expect(trail.workRemains, isFalse);
        expect(h.frameDraws, [
          (start: 1000, end: 4096, onFrameCanvas: true),
          (start: 8192, end: 9000, onFrameCanvas: true),
        ]);
        expect(trail.marker, 8999);
      },
    );

    test('void live tail falls back to newest baked middle marker', () {
      h.fill();
      final trail = h.paint(
        viewStart: 0,
        viewEnd: 9000,
        totalSamples: 9000,
        voidFrom: 8192,
      );
      expect(trail.marker, 8191);
      expect(h.frameDraws, [(start: 8192, end: 9000, onFrameCanvas: true)]);
    });

    test('a window inside one bucket is entirely vector head', () {
      final trail = h.paint(viewStart: 100, viewEnd: 500, totalSamples: 9000);
      expect(trail.workRemains, isTrue);
      expect(h.bakes, [(start: 0, end: 4096, onFrameCanvas: false)]);
      expect(h.frameDraws, [(start: 100, end: 500, onFrameCanvas: true)]);
      expect(trail.marker, 499);
    });
  });

  group('invalidation and retention', () {
    test('destructive key and generation changes clear old buckets', () {
      h.fill();
      h.paint(
        viewStart: 0,
        viewEnd: 9000,
        totalSamples: 9000,
        destructiveKey: const ['other'],
      );
      expect(h.cache.bucketCount, 1);
      expect(h.bakes, [(start: 4096, end: 8192, onFrameCanvas: false)]);
      expect(h.frameDraws, [
        (start: 0, end: 4096, onFrameCanvas: true),
        (start: 8192, end: 9000, onFrameCanvas: true),
      ]);

      h.paint(
        viewStart: 0,
        viewEnd: 9000,
        totalSamples: 9000,
        destructiveKey: const ['other'],
      );
      expect(h.cache.bucketCount, 2);
      h.paint(
        viewStart: 0,
        viewEnd: 9000,
        totalSamples: 9000,
        generation: 1,
        destructiveKey: const ['other'],
      );
      expect(h.cache.bucketCount, 1);
      expect(h.bakes, [(start: 4096, end: 8192, onFrameCanvas: false)]);
    });

    test('buckets under the read finger are not baked', () {
      h.paint(
        viewStart: 100,
        viewEnd: 9000,
        totalSamples: 9000,
        oldestSample: 100,
      );
      expect(h.bakes, [(start: 4096, end: 8192, onFrameCanvas: false)]);
      final trail = h.paint(
        viewStart: 100,
        viewEnd: 9000,
        totalSamples: 9000,
        oldestSample: 100,
      );
      expect(trail.workRemains, isFalse);
      expect(h.frameDraws.first, (start: 100, end: 4096, onFrameCanvas: true));
      expect(h.cache.bucketCount, 1);
    });

    test('far buckets evict and clear drops every retained image', () {
      h.fill();
      final trail = h.paint(
        viewStart: 200000,
        viewEnd: 201000,
        totalSamples: 201000,
      );
      expect(trail.marker, 200999);
      expect(h.bakes, [(start: 196608, end: 200704, onFrameCanvas: false)]);
      expect(h.cache.bucketCount, 1);

      h.cache.clear();
      expect(h.cache.bucketCount, 0);
    });

    test('an empty retained intersection neither bakes nor draws', () {
      final trail = h.paint(viewStart: -100, viewEnd: -50, totalSamples: 9000);
      expect((trail.marker, trail.workRemains), (null, false));
      expect(h.calls, isEmpty);
    });
  });
}
