import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/bucket_series.dart';
import 'block_reduction_cache.dart';

/// Convert a window's sample scale to an absolute-grid reduction block size.
int blockSizeFor(double viewSamples, double graphW) {
  assert(graphW > 0, 'graphW must be positive, got $graphW');
  final size = math.max(1, (viewSamples / graphW).floor());
  if (size < 2 * kBucketSize) return size;
  // Big blocks are bucket multiples, making complete reductions immutable.
  return ((size + kBucketSize - 1) ~/ kBucketSize) * kBucketSize;
}

const int joinBlockSlackBlocks = 2;

/// End of the full join block following [end] on the absolute block grid.
int joinBlockEnd(int end, int blockSize) =>
    (end ~/ blockSize + joinBlockSlackBlocks) * blockSize;

/// Full sample span a render can reduce, including edge and join blocks.
(int, int) foldBlockSpan(double viewStart, double viewEnd, int blockSize) => (
  (viewStart.floor() / blockSize).floor() * blockSize,
  joinBlockEnd(viewEnd.ceil(), blockSize),
);

/// Fixed-capacity vertex buffer with a continuous-primitive carryover tail.
class VertexBatcher {
  new({
    required this.preserveFloats,
    required this.drawThreshold,
    required this.onFlush,
    int capacity = 4096,
  }) : _buf = Float32List(capacity);

  final Float32List _buf;
  final int preserveFloats;
  final int drawThreshold;
  final void Function(Float32List view) onFlush;
  int _len = 0;

  void add(double x, double y) {
    _buf[_len++] = x;
    _buf[_len++] = y;
  }

  bool wouldOverflow(int extraFloats) => _len + extraFloats > _buf.length;

  void flush() {
    if (_len > drawThreshold) {
      onFlush(Float32List.sublistView(_buf, 0, _len));
      for (int i = 0; i < preserveFloats; i++) {
        _buf[i] = _buf[_len - preserveFloats + i];
      }
      _len = preserveFloats;
    }
  }

  void reset() => _len = 0;
}

({VertexBatcher meanLine, VertexBatcher minMaxBand}) _envelopeBatchers(
  Canvas canvas, {
  required Color avgColor,
  required double avgStrokeWidth,
  required Color envColor,
}) {
  final pen = Paint();
  final meanLine = VertexBatcher(
    preserveFloats: 2,
    drawThreshold: 2,
    onFlush: (view) {
      pen
        ..color = avgColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = avgStrokeWidth;
      canvas.drawRawPoints(ui.PointMode.polygon, view, pen);
    },
  );
  final minMaxBand = VertexBatcher(
    preserveFloats: 4,
    drawThreshold: 4,
    onFlush: (view) {
      final vertices = ui.Vertices.raw(ui.VertexMode.triangleStrip, view);
      pen
        ..color = envColor
        ..style = PaintingStyle.fill;
      canvas.drawVertices(vertices, ui.BlendMode.srcOver, pen);
      vertices.dispose();
    },
  );
  return (meanLine: meanLine, minMaxBand: minMaxBand);
}

/// Render one channel's absolute-grid min/average/max envelope.
void drawChannelEnvelope(
  Canvas canvas, {
  required Color color,
  required double graphW,
  required int viewStart,
  required double viewSamples,
  required int blockSize,
  required int renderEnd,
  required int firstUsableSample,
  required int channelIndex,
  required BlockReductionCache reductionCache,
  required EnvelopeSeries series,
  required double Function(double value) valueToY,
  required int clipEnvelopeSamples,
  double avgStrokeWidth = 1.5,
  int avgAlpha = 255,
  int envAlpha = 60,
}) {
  final batchers = _envelopeBatchers(
    canvas,
    avgColor: color.withAlpha(avgAlpha),
    avgStrokeWidth: avgStrokeWidth,
    envColor: color.withAlpha(envAlpha),
  );
  final meanLine = batchers.meanLine;
  final minMaxBand = batchers.minMaxBand;
  final buckets = series.buckets;
  final useBuckets = blockSize >= 2 * buckets.bucketSize;
  final startBlock = (math.max(viewStart, firstUsableSample) / blockSize)
      .floor();
  final endBlock = (renderEnd / blockSize).ceil();

  for (int k = startBlock; k < endBlock; k++) {
    final sStart = k * blockSize;
    final sEnd = math.min(sStart + blockSize, renderEnd);
    final drawStart = math.max(sStart, firstUsableSample);
    if (drawStart >= sEnd) continue;
    final complete = drawStart == sStart && sEnd - sStart == blockSize;
    final r = reductionCache.resolve(
      channel: channelIndex,
      blockIndex: k,
      complete: complete,
      reduce: () => useBuckets
          ? reduceBlockBuckets(series, drawStart, sEnd)
          : reduceBlockExact(series.sampleAt, drawStart, sEnd),
    );
    if (r.count == 0) {
      minMaxBand.flush();
      minMaxBand.reset();
      meanLine.flush();
      meanLine.reset();
      continue;
    }

    final avgY = valueToY(r.sum / r.count);
    final minY = valueToY(r.min);
    final maxY = valueToY(r.max);
    final xPos = (sStart - viewStart) * graphW / viewSamples;
    final nextXPos = (sEnd - viewStart) * graphW / viewSamples;
    meanLine.add(xPos, avgY);

    // One-sample blocks have coincident extrema: zero-area fill is useless.
    if (blockSize > 1 && sStart < clipEnvelopeSamples) {
      minMaxBand.add(xPos, maxY);
      minMaxBand.add(xPos, minY);
      minMaxBand.add(nextXPos, maxY);
      minMaxBand.add(nextXPos, minY);
      if (minMaxBand.wouldOverflow(8)) minMaxBand.flush();
    }
    if (meanLine.wouldOverflow(2)) meanLine.flush();
  }
  minMaxBand.flush();
  meanLine.flush();
}
