import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// Force plate dot cache
//
// The force plate trail draws every sample's CoP dot over the
// minimap-selected window: at 1 ksps a wide window is hundreds of thousands
// of drawCircle calls per frame. CoP -> pixel mapping is window-independent
// (the plate axes are fixed), so dots bake once into immutable textures and
// blit at identity. That is the whole difference from [SegmentedGraphCache]:
// a line segment's x/y mapping moves with the window (its blits need
// corrective transforms and drift bookkeeping); a plate dot's doesn't, so
// there is no drift machinery, no ghost blits, and only a whole-cache config
// stamp.
//
// Sample-space is divided into fixed, absolutely anchored buckets of
// [kForcePlateBucketSpan]. A bucket texture is baked once, after its full
// range exists in the data (gap marking is atomic with the packet append,
// so an appended range's gap set is final) and never rebaked while the
// config stamp holds. Per frame, the window's middle -- the buckets fully
// covered by it -- blits; the partial buckets under the window edges (head,
// tail) vector-draw. The tail doubles as the live edge: the bucket holding
// the newest sample is never baked, so new dots stream in vector until the
// bucket completes. Unbaked middle buckets (refill after a clear) vector-
// draw until the rolling bake sweep reaches them, rightmost first.
//
// A window smaller than one bucket has no full middle and draws all-vector,
// touching nothing here but the geometry.
//
// TODO(plate-affine): a plot-side/dpr change is a uniform affine of every
// bucket texture; instead of clearing with the config stamp, tolerate it
// with a corrective blit (the gh/dpr drift model on [SegmentedGraphCache])
// so a window resize doesn't force a rebuild.
// ---------------------------------------------------------------------------

/// Samples per dot bucket. Bounds both sides of the per-frame/VRAM trade:
/// the vector-drawn live tail (plus head) is at most one bucket each, and
/// the visible-bucket count is windowSpan / [kForcePlateBucketSpan] textures
/// of side^2 x dpr^2 x 4 bytes (~37 MB for the full 10-min retained ring at
/// dpr 1, ~150 MB at dpr 2 -- accepted: full-resolution dots are the
/// requirement).
const int kForcePlateBucketSpan = 4096;

/// Buckets further than this outside the window are disposed. Keeps
/// pan-back blits without an unbounded cache.
const int _kEvictionMarginBuckets = 8;

/// Renders the dot-strokes of samples [start, end) onto [canvas], whose
/// origin is the plate area's top-left (both for bucket textures and for
/// on-frame vector draws). Returns the range's newest-valid-sample record
/// (the painter's marker payload), or null when the range held none. The
/// return of a bake is stored with the bucket; composing the per-frame
/// records left-to-right -- head, middle, tail -- yields the window's
/// newest valid sample, with no data rescan.
typedef ForcePlateDotRenderer<T extends Object> =
    T? Function(Canvas canvas, int start, int end);

/// One frame of inputs for [ForcePlateCache.paint]: the requested window
/// [viewStart, viewEnd) (the controller's effective range, which may
/// overhang the retained data on both ends), the data domain, the square
/// texture geometry ([side] logical px at [dpr]), the cache identity
/// ([generation] identifies the data stream; [configKey] everything that
/// moves the dots -- unit, calibration, tares, corner assignment, side,
/// dpr: a change clears the whole cache, see the file header), and the dot
/// renderer.
typedef ForcePlateFrame<T extends Object> = ({
  int generation,
  List<Object?> configKey,
  double side,
  double dpr,
  int viewStart,
  int viewEnd,
  int oldestSample,
  int totalSamples,
  ForcePlateDotRenderer<T> render,
});

/// What one [ForcePlateCache.paint] produced: [marker] is the newest valid
/// sample in the window (composed from the head/middle/tail range records,
/// see [ForcePlateDotRenderer]); [workRemains] is true when a bake happened
/// this frame and the sweep may have more -- the owner should schedule
/// another frame (static sources never fire repaint on their own).
typedef ForcePlateTrail<T extends Object> = ({T? marker, bool workRemains});

/// One baked bucket: the dots of samples [start, end), plus the range
/// record the renderer returned at bake time.
class _DotBucket<T extends Object> {
  _DotBucket({required this.image, required this.start, required this.marker});

  final ui.Image image;
  final int start;
  final T? marker;

  int get end => start + kForcePlateBucketSpan;

  void dispose() => image.dispose();
}

/// Bake a square [sizePx] physical-pixel image; [draw] works in logical px.
ui.Image _bakeSquare(int sizePx, double dpr, void Function(Canvas) draw) {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder)..scale(dpr));
  final pic = recorder.endRecording();
  final img = pic.toImageSync(sizePx, sizePx);
  pic.dispose();
  return img;
}

/// Write-once per-bucket texture cache for the force plate trail; see the
/// file header for the model. All paint-time coordinates are plate-local:
/// the caller hands over a canvas translated to the plate area's top-left.
class ForcePlateCache<T extends Object> {
  /// Baked buckets ordered by [_DotBucket.start]; never overlapping.
  final List<_DotBucket<T>> _buckets = [];

  int _generation = -1;
  List<Object?> _configKey = const [];

  /// Number of live buckets; test visibility into the maintenance paths.
  @visibleForTesting
  int get bucketCount => _buckets.length;

  void clear() {
    for (final b in _buckets) {
      b.dispose();
    }
    _buckets.clear();
  }

  void dispose() => clear();

  /// Blit the window's fully covered buckets, vector-draw the partial edges
  /// and not-yet-baked middles, and spend one bake on the rightmost
  /// untouched bucket in view. See the file header.
  @useResult
  ForcePlateTrail<T> paint(Canvas canvas, ForcePlateFrame<T> f) {
    if (f.generation != _generation || !listEquals(f.configKey, _configKey)) {
      clear();
      _generation = f.generation;
      _configKey = List.of(f.configKey);
    }

    // The controller window can overhang the retained range (a locked span
    // wider than the data); the trail only ever covers real samples.
    final int s0 = f.viewStart > f.oldestSample ? f.viewStart : f.oldestSample;
    final int s1 = f.viewEnd < f.totalSamples ? f.viewEnd : f.totalSamples;

    const int margin = _kEvictionMarginBuckets * kForcePlateBucketSpan;
    _buckets.removeWhere((b) {
      final keep =
          b.end > f.oldestSample &&
          b.start < s1 + margin &&
          b.end > s0 - margin;
      if (!keep) b.dispose();
      return !keep;
    });

    if (s1 <= s0) return (marker: null, workRemains: false);

    final bool baked = _bakeOne(f, s0, s1);
    final T? marker = _draw(canvas, f, s0, s1);
    return (marker: marker, workRemains: baked);
  }

  /// Bake the rightmost bakeable bucket intersecting the window. Bakeable =
  /// fully formed: the whole range exists in the retained data (the bucket
  /// holding the newest sample is partial and streams vector instead; one
  /// under the ring's read finger has lost samples forever and must not be
  /// baked from reads outside the retained range).
  bool _bakeOne(ForcePlateFrame<T> f, int s0, int s1) {
    const span = kForcePlateBucketSpan;
    for (
      int b = ((s1 - 1) ~/ span) * span;
      b + span > s0 && b >= f.oldestSample;
      b -= span
    ) {
      if (b + span > f.totalSamples) continue;
      if (_buckets.any((bucket) => bucket.start == b)) continue;

      T? marker;
      final image = _bakeSquare(
        (f.side * f.dpr).ceil(),
        f.dpr,
        (c) => marker = f.render(c, b, b + span),
      );
      // Sorted insert: no bucket with this start exists (checked above).
      final at = _buckets.indexWhere((bucket) => bucket.start > b);
      _buckets.insert(
        at < 0 ? _buckets.length : at,
        _DotBucket(image: image, start: b, marker: marker),
      );
      return true;
    }
    return false;
  }

  /// Draw head, middle, tail in that order and return the newest non-null
  /// range record -- the order is ascending sample time, so the last
  /// non-null IS the window's newest valid sample (a baked bucket's record
  /// stands in for its range; a mid-refill unbaked bucket reports its
  /// vector draw's record directly).
  T? _draw(Canvas canvas, ForcePlateFrame<T> f, int s0, int s1) {
    const span = kForcePlateBucketSpan;
    // First bucket boundary at or past s0: everything before it is the head.
    final int midStart = s0 % span == 0 ? s0 : (s0 ~/ span + 1) * span;

    T? marker;
    // The window sitting inside one bucket (midStart > s1) renders all head.
    if (midStart > s0) {
      marker = f.render(canvas, s0, midStart < s1 ? midStart : s1);
    }

    int bi = 0;
    int b;
    for (b = midStart; b + span <= s1; b += span) {
      while (bi < _buckets.length && _buckets[bi].start < b) {
        bi++;
      }
      final bucket = (bi < _buckets.length && _buckets[bi].start == b)
          ? _buckets[bi]
          : null;
      final m = bucket != null
          ? bucket.marker
          : f.render(canvas, b, b + span); // refill gap: vector until baked
      if (bucket != null) _blit(canvas, bucket.image, f.side);
      if (m != null) marker = m;
    }

    if (b < s1) {
      final m = f.render(canvas, b, s1);
      if (m != null) marker = m;
    }
    return marker;
  }

  /// Identity blit: bake and display share (side, dpr) -- the config stamp
  /// clears on any change -- so there is no resampling to filter.
  void _blit(Canvas canvas, ui.Image image, double side) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, side, side),
      Paint()..filterQuality = FilterQuality.none,
    );
  }
}
