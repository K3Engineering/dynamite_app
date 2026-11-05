import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meta/meta.dart';

import 'affine2.dart';

// ---------------------------------------------------------------------------
// Affine dot cache
//
// Samples are partitioned into absolutely anchored, write-once ranges of
// [kAffineDotBucketSpan]. Full ranges in the view are baked into rectangular
// textures; partial window edges and the bucket containing the live sample
// always draw as vectors. One missing or stale visible bucket bakes per frame,
// rightmost first, to spread rasterization across frames.
//
// Unlike the force plate, a dot's mapping may change without changing its data.
// Axis transforms and linear detrending are both [Affine2], so a stale texture
// can blit through currentProjection * oldProjection.inverse. That is safe only
// when the old image covers the current raw-space view: clipped-away dots cannot
// be recovered by transforming the surviving pixels. Uncovered stale buckets
// vector-draw until their rolling rebake. Size changes also vector-draw because
// [Affine2.covers] compares rectangles of equal logical dimensions.
// ---------------------------------------------------------------------------

const int kAffineDotBucketSpan = 4096;
const int _kEvictionMarginBuckets = 8;

/// Draw samples [start, end) as fixed-pixel-radius circles through [project].
/// Return the newest valid marker in the range, or null if there is none.
typedef AffineDotRenderer<T extends Object> = T? Function(
  Canvas canvas,
  int start,
  int end,
  ({double x, double y}) Function(double x, double y) project,
);

/// The data identity, view geometry and renderer supplied to one cache paint.
/// [generation] and [destructiveKey] invalidate data or non-affine rendering;
/// projection, size and DPR changes instead retain and remap eligible textures.
typedef AffineDotFrame<T extends Object> = ({
  int generation,
  List<Object?> destructiveKey,
  double width,
  double height,
  double dpr,
  Affine2 projection,
  int viewStart,
  int viewEnd,
  int oldestSample,
  int totalSamples,
  AffineDotRenderer<T> render,
});

typedef AffineDotTrail<T extends Object> = ({T? marker, bool workRemains});

class _AffineDotBucket<T extends Object> {
  const new({
    required this.image,
    required this.start,
    required this.marker,
    required this.projection,
    required this.width,
    required this.height,
    required this.dpr,
  });

  final ui.Image image;
  final int start;
  final T? marker;
  final Affine2 projection;
  final double width;
  final double height;
  final double dpr;

  int get end => start + kAffineDotBucketSpan;

  bool isCurrent(AffineDotFrame<T> f) =>
      projection == f.projection &&
      width == f.width &&
      height == f.height &&
      dpr == f.dpr;

  void dispose() => image.dispose();
}

/// Rasterize a full logical frame into a physical-pixel texture.
ui.Image _bakeImage(
  int widthPx,
  int heightPx,
  double dpr,
  void Function(Canvas canvas) draw,
) {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder)..scale(dpr));
  final picture = recorder.endRecording();
  final image = picture.toImageSync(widthPx, heightPx);
  picture.dispose();
  return image;
}

/// Fixed-sample-bucket texture cache with safe affine reuse; see file header.
class AffineDotCache<T extends Object> {
  /// Non-overlapping buckets ordered by ascending sample start.
  final List<_AffineDotBucket<T>> _buckets = [];

  int _generation = -1;
  List<Object?> _destructiveKey = const [];

  @visibleForTesting
  int get bucketCount => _buckets.length;

  void clear() {
    for (final bucket in _buckets) {
      bucket.dispose();
    }
    _buckets.clear();
  }

  void dispose() => clear();

  @useResult
  AffineDotTrail<T> paint(Canvas canvas, AffineDotFrame<T> f) {
    if (f.generation != _generation ||
        !listEquals(f.destructiveKey, _destructiveKey)) {
      clear();
      _generation = f.generation;
      _destructiveKey = List.of(f.destructiveKey);
    }

    // The requested window may overhang retained samples on either side.
    final int s0 = f.viewStart > f.oldestSample ? f.viewStart : f.oldestSample;
    final int s1 = f.viewEnd < f.totalSamples ? f.viewEnd : f.totalSamples;

    const int margin = _kEvictionMarginBuckets * kAffineDotBucketSpan;
    _buckets.removeWhere((bucket) {
      final keep =
          bucket.end > f.oldestSample &&
          bucket.start < s1 + margin &&
          bucket.end > s0 - margin;
      if (!keep) bucket.dispose();
      return !keep;
    });

    if (s1 <= s0) return (marker: null, workRemains: false);

    final bool baked = _bakeOne(f, s0, s1);
    final T? marker = _draw(canvas, f, s0, s1);
    return (marker: marker, workRemains: baked);
  }

  /// Bake one rightmost missing/stale bucket whose entire sample range exists.
  /// The bucket under the ring read finger or containing the newest sample is
  /// incomplete and remains vector-drawn.
  bool _bakeOne(AffineDotFrame<T> f, int s0, int s1) {
    const int span = kAffineDotBucketSpan;
    for (
      int start = ((s1 - 1) ~/ span) * span;
      start + span > s0 && start >= f.oldestSample;
      start -= span
    ) {
      if (start + span > f.totalSamples) continue;
      final int oldIndex = _buckets.indexWhere((b) => b.start == start);
      if (oldIndex >= 0 && _buckets[oldIndex].isCurrent(f)) continue;

      T? marker;
      final ui.Image image = _bakeImage(
        (f.width * f.dpr).ceil(),
        (f.height * f.dpr).ceil(),
        f.dpr,
        (canvas) => marker = f.render(
          canvas,
          start,
          start + span,
          f.projection.project,
        ),
      );
      final bucket = _AffineDotBucket<T>(
        image: image,
        start: start,
        marker: marker,
        projection: f.projection,
        width: f.width,
        height: f.height,
        dpr: f.dpr,
      );
      if (oldIndex >= 0) {
        _buckets[oldIndex].dispose();
        _buckets[oldIndex] = bucket;
      } else {
        final int at = _buckets.indexWhere((b) => b.start > start);
        _buckets.insert(at < 0 ? _buckets.length : at, bucket);
      }
      return true;
    }
    return false;
  }

  /// Compose markers in sample order: a later non-null record supersedes an
  /// earlier one, whether it came from a texture bake or a direct vector draw.
  T? _draw(Canvas canvas, AffineDotFrame<T> f, int s0, int s1) {
    const int span = kAffineDotBucketSpan;
    final int midStart = s0 % span == 0 ? s0 : (s0 ~/ span + 1) * span;

    T? marker;
    if (midStart > s0) {
      // A window inside one bucket is entirely head, never middle or tail.
      marker = f.render(
        canvas,
        s0,
        midStart < s1 ? midStart : s1,
        f.projection.project,
      );
    }

    int bucketIndex = 0;
    int start;
    for (start = midStart; start + span <= s1; start += span) {
      while (bucketIndex < _buckets.length &&
          _buckets[bucketIndex].start < start) {
        bucketIndex++;
      }
      final bucket =
          (bucketIndex < _buckets.length &&
              _buckets[bucketIndex].start == start)
          ? _buckets[bucketIndex]
          : null;

      T? rangeMarker;
      if (bucket == null) {
        rangeMarker = f.render(
          canvas,
          start,
          start + span,
          f.projection.project,
        );
      } else if (bucket.isCurrent(f)) {
        _blit(canvas, bucket, null);
        rangeMarker = bucket.marker;
      } else if (bucket.width == f.width &&
          bucket.height == f.height &&
          bucket.projection.covers(f.projection, f.width, f.height)) {
        _blit(canvas, bucket, f.projection.compose(bucket.projection.inverse));
        rangeMarker = bucket.marker;
      } else {
        // In particular, zooming out can reveal dots that the old texture
        // clipped away, so blitting it would leave part of the range blank.
        rangeMarker = f.render(
          canvas,
          start,
          start + span,
          f.projection.project,
        );
      }
      if (rangeMarker != null) marker = rangeMarker;
    }

    if (start < s1) {
      final T? m = f.render(canvas, start, s1, f.projection.project);
      if (m != null) marker = m;
    }
    return marker;
  }

  /// Draw every source texel into the old logical dimensions. [remap] maps
  /// those logical coordinates into the current frame; null is an identity
  /// blit. Bilinear filtering avoids the seams observed with nearest sampling.
  void _blit(Canvas canvas, _AffineDotBucket<T> bucket, Affine2? remap) {
    final paint = Paint()..filterQuality = FilterQuality.low;
    final ui.Image image = bucket.image;
    final Rect src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final Rect dst = Rect.fromLTWH(0, 0, bucket.width, bucket.height);
    if (remap == null) {
      canvas.drawImageRect(image, src, dst, paint);
      return;
    }
    canvas.save();
    canvas.transform(remap.canvasTransform);
    canvas.drawImageRect(image, src, dst, paint);
    canvas.restore();
  }
}
