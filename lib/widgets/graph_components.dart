import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/app_settings.dart';

// ---------------------------------------------------------------------------
// Shared graph layout constants
// ---------------------------------------------------------------------------

/// Horizontal/vertical padding shared by the graph painters and the gesture
/// areas. [kGraphRightSpace] reserves room for the Y-axis labels.
const double kGraphLeftSpace = 8;
const double kGraphRightSpace = 56;
const double kGraphBottomSpace = 24;

/// Width available for plotting given a full widget [totalWidth].
double graphPlotWidth(double totalWidth) =>
    totalWidth - kGraphLeftSpace - kGraphRightSpace;

// ---------------------------------------------------------------------------
// Shared Graph Data Source
// ---------------------------------------------------------------------------

class CacheConfig {
  final double graphW;
  final double graphH;
  final int viewSamples;
  final double yMin;
  final double yMax;
  final List<double> tares;

  /// Device pixel ratio the tile images are rasterized at. A dpr change
  /// (browser zoom, monitor move) must drop the bitmap cache.
  final double dpr;

  CacheConfig(
    this.graphW,
    this.graphH,
    this.viewSamples,
    this.yMin,
    this.yMax,
    this.tares,
    this.dpr,
  );

  bool matches(CacheConfig other) {
    if ((graphW - other.graphW).abs() > 0.1) return false;
    if ((graphH - other.graphH).abs() > 0.1) return false;
    if (viewSamples != other.viewSamples) return false;
    if ((yMin - other.yMin).abs() > 1e-6) return false;
    if ((yMax - other.yMax).abs() > 1e-6) return false;
    if (dpr != other.dpr) return false;
    if (tares.length != other.tares.length) return false;
    for (int i = 0; i < tares.length; i++) {
      if ((tares[i] - other.tares[i]).abs() > 1e-6) return false;
    }
    return true;
  }
}

class GraphLineCache {
  CacheConfig? config;
  int chunkSamples = 1000;

  /// Fully-populated tiles rasterized once via [ui.Picture.toImageSync].
  ///
  /// On web there is no engine raster cache: a cached [ui.Picture] is re-
  /// rasterized every frame (measured ~1.2ms of Skwasm raster per tile), so
  /// pictures only save Dart-side recording time. Baking each immutable tile
  /// into a GPU-resident [ui.Image] pays that raster cost once and makes the
  /// per-frame cost a texture blit.
  final Map<int, ui.Image> images = {};

  /// Number of consecutive paints whose [config] matched. Image creation is
  /// gated on this so squeeze mode (viewSamples grows every frame => config
  /// mismatch => full invalidate every frame) never pays toImageSync for
  /// tiles that are dropped on the next frame.
  int stableFrames = 0;

  void invalidate() {
    for (final img in images.values) {
      img.dispose();
    }
    images.clear();
    config = null;
    stableFrames = 0;
  }
}

/// Number of samples reduced into a single envelope/line "block".
///
/// One block becomes one min/avg/max reduction and one polyline vertex. When
/// zoomed in past 1 sample/pixel this clamps to 1 (one block per sample). The
/// last block in a range is allowed to be short.
int blockSizeFor(int viewSamples, double graphW) {
  if (graphW <= 0) return 1;
  // floor => >= 1 sample/block, so the polyline never has more vertices than
  // pixels. The remainder (viewSamples % blockSize) lands in the short final block.
  return math.max(1, (viewSamples / graphW).floor());
}

/// Pick a cache tile size (in samples) for the given zoom. Aims for ~200 px
/// wide tiles and rounds down to a whole multiple of [blockSize] so block
/// boundaries never straddle a tile boundary.
int chunkSamplesFor(double samplesPerPixel, int blockSize) {
  int target = (200 * samplesPerPixel).round();
  target = math.max(blockSize, target);
  // Snap down to a whole multiple of blockSize: tiles must tile the block grid
  // exactly, otherwise a block straddling a seam would be reduced twice.
  final snapped = (target ~/ blockSize) * blockSize;
  assert(snapped % blockSize == 0);
  return snapped == 0 ? blockSize : snapped;
}

/// A single channel's raw circular-buffer data plus its precomputed extremes
/// and tare offset. Returned by [GraphDataSource.channel].
typedef ChannelSeries = ({
  List<int> data,
  double min,
  double max,
  double tare,
  int bucketSize,
  Int32List bucketMins,
  Int32List bucketMaxs,
  Int32List bucketSums,
});

/// Data interface required by the shared graph components (main graph, minimap, etc).
/// This allows the components to render either live DataHub data or static SessionData.
///
/// Sources are not required to be [ChangeNotifier]s; instead they expose a
/// [repaint] [Listenable] that fires when their data changes (a never-firing
/// listenable is fine for static data). This keeps the interface usable by both
/// live and static sources, and leaves room for composed/derived sources later.
abstract interface class GraphDataSource {
  /// Total number of logical samples generated so far (can exceed bufferCapacity).
  int get totalSamples;

  /// The size of the circular buffer. Used to modulus array indices.
  int get bufferCapacity;

  /// The oldest available sample index (absolute time).
  int get oldestSample;

  /// The sample rate of the data (Hz).
  int get sampleRate;

  /// The calibration slope used to convert raw counts to kgf.
  double get calibrationSlope;

  /// Notifies listeners when the underlying data changes.
  Listenable get repaint;

  /// Returns the series (data + extremes + tare) for a given channel index.
  ChannelSeries channel(int channelIndex);

  /// The integer value representing a dropped/missing sample.
  /// The graph rendering will skip over these values and draw missing data hatchings.
  int? get missingSampleSentinel;
}

/// A [Listenable] that never fires; use as [GraphDataSource.repaint] for static
/// data sources (e.g. a loaded session).
final Listenable kNeverRepaints = _NeverListenable();

class _NeverListenable extends Listenable {
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

// ---------------------------------------------------------------------------
// Graph viewport controller (shared between force graph, derivative, minimap)
// ---------------------------------------------------------------------------

class GraphController extends ChangeNotifier {
  final int minLiveSpan;

  GraphController({this.minLiveSpan = 0})
    : _liveSpan = minLiveSpan > 0 ? minLiveSpan : null;

  /// Start of visible window in samples.
  int _viewStart = 0;
  int get viewStart => _viewStart;

  /// End of visible window in samples. Null means "follow live edge".
  int? _viewEnd;
  int? get viewEnd => _viewEnd;

  /// Whether we're following the live edge (auto-scroll with new data).
  bool _isLive = true;
  bool get isLive => _isLive;

  /// When in live mode and zoomed in, this is the fixed span to show
  /// from the right edge. Null means "show all data from _viewStart" (up to 10 minutes).
  int? _liveSpan;
  int? get liveSpan => _liveSpan;

  /// Snap to live mode -- follow the right edge.
  /// If [span] is provided, locks to that scrolling window.
  /// If not provided, it intelligently decides between full view or default scrolling window.
  void goLive({int? span, int? totalSamples, int? oldestSample}) {
    if (span != null) {
      // Explicitly lock to a span (used by zoom out when it hits max)
      _liveSpan = span;
    } else if (totalSamples != null &&
        oldestSample != null &&
        _viewEnd != null) {
      final currentSpan = _viewEnd! - _viewStart;
      final availableData = totalSamples - oldestSample;

      if (currentSpan >= availableData) {
        // User zoomed out to see all available data
        if (currentSpan > minLiveSpan) {
          // If they zoomed out beyond the minLiveSpan (or available data is huge),
          // they want to see everything auto-expand.
          _liveSpan = null;
        } else {
          // They zoomed out, but we don't have much data yet.
          // Lock to minimum span so it cleanly starts scrolling once it hits 20s.
          _liveSpan = minLiveSpan;
        }
      } else {
        // User is zoomed in to a specific window, lock to it
        _liveSpan = currentSpan;
      }
    } else if (_viewEnd != null) {
      // Fallback
      _liveSpan = _viewEnd! - _viewStart;
    }

    _isLive = true;
    _viewEnd = null;
    notifyListeners();
  }

  /// Set a specific visible window (exits live mode).
  void setWindow(int start, int end) {
    _viewStart = start;
    _viewEnd = end;
    _isLive = false;
    _liveSpan = null;
    notifyListeners();
  }

  /// Get the effective visible range given total data size.
  (int start, int end) effectiveRange(
    int totalSamples,
    int oldestSample, {
    int? bufferCapacity,
  }) {
    if (_isLive || _viewEnd == null) {
      final int maxSpan = math.max(minLiveSpan, totalSamples - oldestSample);
      int span = _liveSpan ?? maxSpan;
      if (bufferCapacity != null && span > bufferCapacity) {
        span = bufferCapacity;
      }
      return (totalSamples - span, totalSamples);
    }
    return (_viewStart, _viewEnd!.clamp(_viewStart + 1, totalSamples));
  }

  /// Whether the current window covers all available data.
  ///
  /// Every plot renders in one of two modes:
  ///   * squeeze -- the window spans the whole history, so the x-mapping of
  ///     every sample recompresses as new data arrives;
  ///   * slide   -- a fixed-span window slides over the data.
  bool isSqueeze(int totalSamples, int oldestSample) {
    final (s, e) = effectiveRange(totalSamples, oldestSample);
    return e - s >= totalSamples - oldestSample;
  }

  /// Apply the window [newStart, newStart + span), clamped to the available
  /// data. Snaps to live mode when the window reaches the right edge.
  ///
  /// This is the single funnel for every window-moving interaction (pan,
  /// minimap tap/drag, gesture pan); [zoomTo] handles the zooming ones.
  void applyWindow(int newStart, int span, int totalSamples, int oldestSample) {
    int newEnd = newStart + span;
    final minStart = math.min(oldestSample, totalSamples - span);

    if (newStart < minStart) {
      newStart = minStart;
      newEnd = newStart + span;
    }
    if (newEnd >= totalSamples) {
      // Snap to live if the window reaches the right edge. goLive derives the
      // locked span from the window set here.
      _viewStart = newStart;
      _viewEnd = newEnd;
      goLive(totalSamples: totalSamples, oldestSample: oldestSample);
      return;
    }

    _viewStart = newStart;
    _viewEnd = newEnd;
    _isLive = false;
    _liveSpan = null;
    notifyListeners();
  }

  /// Zoom so the window becomes [newSpan] samples (clamped to a ~50 sample
  /// minimum and the available data), anchored at [focalFraction] (0.0 = left
  /// edge, 1.0 = right edge) of the base window [baseStart, baseStart +
  /// baseSpan). The base window is the current one for wheel/button zoom, or
  /// the gesture-start window for pinch.
  ///
  /// When [anchorLiveEdge] and the focal point is near the right edge, the
  /// anchor snaps to the right edge so we stay live without tracking jitter.
  void zoomTo(
    int newSpan,
    double focalFraction, {
    required int baseStart,
    required int baseSpan,
    required bool anchorLiveEdge,
    required int totalSamples,
    required int oldestSample,
  }) {
    final maxSpan = math.max(totalSamples - oldestSample, minLiveSpan);
    // Minimum ~50 samples visible (50ms at 1kHz)
    final span = newSpan.clamp(50, maxSpan);

    double effectiveFocal = focalFraction;
    if (anchorLiveEdge && focalFraction > 0.8) {
      effectiveFocal = 1.0;
    }

    final focal = baseStart + (effectiveFocal * baseSpan).round();
    int newStart = focal - (effectiveFocal * span).round();
    int newEnd = newStart + span;

    final minStart = math.min(oldestSample, totalSamples - span);

    if (newStart < minStart) {
      newStart = minStart;
      newEnd = newStart + span;
    }

    if (newEnd >= totalSamples) {
      // At the right edge -- enter/stay live. Unlike applyWindow, a zoom that
      // hits max span means "show everything" (liveSpan = null, auto-expand).
      _viewStart = totalSamples - span; // Force right-align
      _viewEnd = totalSamples;
      goLive(
        span: span >= maxSpan ? null : span,
        totalSamples: totalSamples,
        oldestSample: oldestSample,
      );
      return;
    }

    _viewStart = newStart;
    _viewEnd = newEnd;
    _isLive = false;
    _liveSpan = null;
    notifyListeners();
  }

  /// Pan by a delta in samples (negative = left, positive = right).
  void pan(
    int deltaSamples,
    int totalSamples,
    int oldestSample,
    int bufferCapacity,
  ) {
    final (s, e) = effectiveRange(
      totalSamples,
      oldestSample,
      bufferCapacity: bufferCapacity,
    );
    applyWindow(s + deltaSamples, e - s, totalSamples, oldestSample);
  }

  /// Center the current window (span preserved) on [centerSample].
  void centerOn(
    int centerSample,
    int totalSamples,
    int oldestSample,
    int bufferCapacity,
  ) {
    final (s, e) = effectiveRange(
      totalSamples,
      oldestSample,
      bufferCapacity: bufferCapacity,
    );
    final span = e - s;
    applyWindow(centerSample - span ~/ 2, span, totalSamples, oldestSample);
  }

  /// Zoom by a factor around a focal point (0.0 = left edge, 1.0 = right edge).
  void zoom(
    double factor,
    double focalFraction,
    int totalSamples,
    int oldestSample,
    int bufferCapacity,
  ) {
    final (s, e) = effectiveRange(
      totalSamples,
      oldestSample,
      bufferCapacity: bufferCapacity,
    );
    final span = e - s;
    zoomTo(
      (span / factor).round(),
      focalFraction,
      baseStart: s,
      baseSpan: span,
      anchorLiveEdge: _isLive,
      totalSamples: totalSamples,
      oldestSample: oldestSample,
    );
  }

  /// Reset to show all data in live mode (fully zoomed out).
  void reset() {
    _viewStart = 0;
    _viewEnd = null;
    _liveSpan = null;
    _isLive = true;
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Channel colors
// ---------------------------------------------------------------------------

Color getChannelColor(int index) {
  const colors = [
    Colors.blueAccent,
    Colors.deepOrangeAccent,
    Colors.green,
    Colors.purple,
  ];
  return colors[index % colors.length];
}

/// Shared mouse-wheel zoom for graph surfaces (main graphs and minimap):
/// zooms the controller window about the cursor position.
void _handleGraphPointerScroll(
  PointerSignalEvent event,
  GraphDataSource data,
  GraphController ctrl,
  double graphWidth,
) {
  if (event is! PointerScrollEvent) return;
  final totalSamples = data.totalSamples;
  if (totalSamples == 0 || graphWidth <= 0) return;

  final focalFrac = ((event.localPosition.dx - kGraphLeftSpace) / graphWidth)
      .clamp(0.0, 1.0);
  final zoomFactor = event.scrollDelta.dy < 0 ? 1.2 : 1 / 1.2;
  ctrl.zoom(
    zoomFactor,
    focalFrac,
    totalSamples,
    data.oldestSample,
    data.bufferCapacity,
  );
}

// ---------------------------------------------------------------------------
// Minimap
// ---------------------------------------------------------------------------

/// Max relative scale drift (horizontal or vertical) tolerated when reusing
/// the baked minimap image via an affine blit before rebaking. Bounds the
/// transient quality loss: a 1px feature is at worst (1 - drift) of its true
/// size between rebakes.
const double kMinimapMaxDrift = 0.02;

/// Max width (logical px) of the fresh-data sliver (samples newer than the
/// baked image) drawn as vectors each frame before rebaking absorbs it.
const double kMinimapMaxSliverPx = 40;

/// Every this many incremental rebakes, do a full vector rebake to purge the
/// blur that repeated image->image resampling accumulates.
const int kMinimapFullRebakeEvery = 20;

class Minimap extends StatefulWidget {
  final GraphDataSource dataSource;
  final List<int> activeChannels;
  final GraphController graphCtrl;
  final List<Color> channelColors;

  const Minimap({
    super.key,
    required this.dataSource,
    required this.activeChannels,
    required this.graphCtrl,
    required this.channelColors,
  });

  @override
  State<Minimap> createState() => _MinimapState();
}

class _MinimapState extends State<Minimap> {
  final _MinimapBakeCache _cache = _MinimapBakeCache();

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  /// Span of the samples the minimap squeezes into its width.
  int _mapSpan(int totalSamples, int oldestSample) =>
      math.max(totalSamples - oldestSample, widget.graphCtrl.minLiveSpan);

  void _onMinimapTap(TapDownDetails d, double graphWidth) {
    final totalSamples = widget.dataSource.totalSamples;
    if (totalSamples == 0 || graphWidth <= 0) return;
    final oldestSample = widget.dataSource.oldestSample;
    final frac = ((d.localPosition.dx - kGraphLeftSpace) / graphWidth).clamp(
      0.0,
      1.0,
    );
    final mapSpan = _mapSpan(totalSamples, oldestSample);
    final mapStart = totalSamples - mapSpan;
    widget.graphCtrl.centerOn(
      mapStart + (frac * mapSpan).round(),
      totalSamples,
      oldestSample,
      widget.dataSource.bufferCapacity,
    );
  }

  void _onMinimapDrag(DragUpdateDetails d, double graphWidth) {
    final totalSamples = widget.dataSource.totalSamples;
    if (totalSamples == 0 || graphWidth <= 0) return;
    final oldestSample = widget.dataSource.oldestSample;
    final samplesPerPixel = _mapSpan(totalSamples, oldestSample) / graphWidth;
    widget.graphCtrl.pan(
      (d.delta.dx * samplesPerPixel).round(),
      totalSamples,
      oldestSample,
      widget.dataSource.bufferCapacity,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphWidth = graphPlotWidth(constraints.maxWidth);
        return SizedBox(
          height: 32,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerSignal: (e) => _handleGraphPointerScroll(
              e,
              widget.dataSource,
              widget.graphCtrl,
              graphWidth,
            ),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _onMinimapTap(d, graphWidth),
              onHorizontalDragUpdate: (d) => _onMinimapDrag(d, graphWidth),
              child: CustomPaint(
                foregroundPainter: _MinimapPainter(
                  widget.dataSource,
                  widget.activeChannels,
                  widget.graphCtrl,
                  widget.channelColors,
                  colorScheme,
                  dpr,
                  _cache,
                ),
                size: Size.infinite,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Affine-reuse cache for the minimap's squeezed waveform.
///
/// On web every [ui.Picture] is re-executed by Skia each frame, so re-drawing
/// the full waveform (~one AA polyline vertex + two envelope vertices per
/// pixel column per channel) costs ~13ms of raster time per frame. Both axis
/// mappings are affine, so a baked bitmap stays valid under squeeze/slide up
/// to a small scale drift: each frame it is blitted with a corrective affine
/// transform and only the fresh-data sliver is drawn as vectors. When drift
/// or sliver exceed their thresholds the image is rebaked -- usually
/// incrementally (old image blit + sliver -> new image, cheap), with a full
/// vector rebake every [kMinimapFullRebakeEvery] incrementals to purge
/// accumulated resampling blur.
class _MinimapBakeCache {
  ui.Image? image;

  // Mapping the image was baked under: image x in [0, gw) covers samples
  // [start, start + span); y in [0, gh) covers tare-subtracted raw values
  // [rawMax, rawMin] (shared by all channels -- tares cancel out of the
  // affine, see _MinimapPainter._blitBaked).
  int start = 0;
  int span = 1;

  /// totalSamples at bake time; content right of x(end) is not in the image.
  int end = 0;
  double rawMin = 0;
  double rawMax = 1;

  // Config the image was baked under (mismatch => full rebake).
  double gw = -1;
  double gh = -1;
  double dpr = -1;
  List<int> channels = const [];
  List<double> tares = const [];
  List<Color> colors = const [];

  int incrementalBakes = 0;

  void dispose() {
    image?.dispose();
    image = null;
  }
}

class _MinimapPainter extends CustomPainter {
  final GraphDataSource _data;
  final List<int> _activeIndices;
  final GraphController _ctrl;
  final List<Color> _colors;
  final ColorScheme _colorScheme;
  final double _dpr;
  final _MinimapBakeCache _cache;

  _MinimapPainter(
    this._data,
    this._activeIndices,
    this._ctrl,
    this._colors,
    this._colorScheme,
    this._dpr,
    this._cache,
  ) : super(repaint: Listenable.merge([_data.repaint, _ctrl]));

  @override
  void paint(Canvas canvas, Size size) {
    // TEMP PERF: measure total minimap paint plus loop/draw split.
    final sw = Stopwatch()..start();
    final perf = EnvelopePerf();

    const double leftSpace = 8;
    const double rightSpace = 56;
    const double vPad = 2;

    canvas.translate(leftSpace, vPad);
    final gw = size.width - leftSpace - rightSpace;
    final gh = size.height - vPad * 2;

    if (gw <= 0 || gh <= 0) return;

    // Background
    final bgPaint = Paint()..color = _colorScheme.surface;
    canvas.drawRect(Rect.fromLTWH(0, 0, gw, gh), bgPaint);

    final totalSamples = _data.totalSamples;
    if (totalSamples == 0) return;

    final oldestSample = _data.oldestSample;
    final mapSpan = math.max(totalSamples - oldestSample, _ctrl.minLiveSpan);
    final mapStart = totalSamples - mapSpan;

    // Compute global min/max (raw, tare-subtracted) for full data
    double rawMax = 10000;
    double rawMin = -10000;
    for (final ch in _activeIndices) {
      final s = _data.channel(ch);
      final mx = s.max - s.tare;
      final mn = s.min - s.tare;
      if (mx > rawMax) rawMax = mx;
      if (mn < rawMin) rawMin = mn;
    }

    final dataRange = rawMax - rawMin;
    if (dataRange <= 0) return;

    final tares = [for (final ch in _activeIndices) _data.channel(ch).tare];

    _paintWaveform(
      canvas,
      gw,
      gh,
      totalSamples,
      mapStart,
      mapSpan,
      rawMin,
      rawMax,
      tares,
      perf,
    );

    // Viewport highlight
    final (viewStart, viewEnd) = _ctrl.effectiveRange(
      totalSamples,
      oldestSample,
      bufferCapacity: _data.bufferCapacity,
    );
    final double x1 = (viewStart - mapStart) * gw / mapSpan;
    final double x2 = (viewEnd - mapStart) * gw / mapSpan;

    // Dim areas outside viewport
    final dimPaint = Paint()..color = _colorScheme.onSurface.withAlpha(60);
    if (x1 > 0) canvas.drawRect(Rect.fromLTWH(0, 0, x1, gh), dimPaint);
    if (x2 < gw) canvas.drawRect(Rect.fromLTWH(x2, 0, gw - x2, gh), dimPaint);

    // Viewport border
    final vpBorder = Paint()
      ..color = _colorScheme.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(Rect.fromLTRB(x1, 0, x2, gh), vpBorder);

    PerfStats.addMinimapPaint(
      sw.elapsedMicroseconds,
      perf.loopMicros,
      perf.drawMicros,
    );
  }

  /// Blit the baked waveform under the current mapping and draw the fresh
  /// sliver as vectors, rebaking first (incrementally or fully) if drift or
  /// sliver width exceed their thresholds.
  void _paintWaveform(
    Canvas canvas,
    double gw,
    double gh,
    int totalSamples,
    int mapStart,
    int mapSpan,
    double rawMin,
    double rawMax,
    List<double> tares,
    EnvelopePerf perf,
  ) {
    final c = _cache;

    bool fullRebake =
        c.image == null ||
        (gw - c.gw).abs() > 0.1 ||
        (gh - c.gh).abs() > 0.1 ||
        _dpr != c.dpr ||
        !listEquals(_activeIndices, c.channels) ||
        !listEquals(tares, c.tares) ||
        !listEquals(_colors, c.colors);

    bool needsBake = fullRebake;
    if (!needsBake) {
      final double xScale = c.span / mapSpan;
      final double yScale = (c.rawMax - c.rawMin) / (rawMax - rawMin);
      final double sliverPx = (totalSamples - c.end) * gw / mapSpan;
      needsBake =
          (1 - xScale).abs() > kMinimapMaxDrift ||
          (1 - yScale).abs() > kMinimapMaxDrift ||
          sliverPx > kMinimapMaxSliverPx;
      if (needsBake) {
        // Not worth incremental reuse if the baked content has mostly
        // scrolled off, or if it's time to purge resampling blur.
        final double bakedRightPx = (c.end - mapStart) * gw / mapSpan;
        if (bakedRightPx < gw * 0.25 ||
            c.incrementalBakes >= kMinimapFullRebakeEvery) {
          fullRebake = true;
        }
      }
    }

    if (needsBake) {
      final recorder = ui.PictureRecorder();
      final bake = Canvas(recorder);
      bake.scale(_dpr);
      if (fullRebake) {
        _drawWaveformColumns(
          bake,
          gw,
          gh,
          mapStart,
          mapSpan,
          rawMin,
          rawMax,
          tares,
          pxFrom: 0,
          perf: perf,
        );
        c.incrementalBakes = 0;
      } else {
        // Incremental: reproject the previous bake and vector-render only the
        // sliver. Raster cost of this bake is one blit + a few columns.
        _blitBaked(bake, gw, gh, mapStart, mapSpan, rawMin, rawMax);
        _drawSliver(bake, gw, gh, mapStart, mapSpan, rawMin, rawMax, tares, perf);
        c.incrementalBakes++;
      }
      final pic = recorder.endRecording();
      final img = pic.toImageSync((gw * _dpr).ceil(), (gh * _dpr).ceil());
      pic.dispose();
      c.image?.dispose();
      c.image = img;
      c.start = mapStart;
      c.span = mapSpan;
      c.end = totalSamples;
      c.rawMin = rawMin;
      c.rawMax = rawMax;
      c.gw = gw;
      c.gh = gh;
      c.dpr = _dpr;
      c.channels = List.of(_activeIndices);
      c.tares = tares;
      c.colors = List.of(_colors);
      PerfStats.addMinimapBake(full: fullRebake); // TEMP PERF
    }

    _blitBaked(canvas, gw, gh, mapStart, mapSpan, rawMin, rawMax);
    _drawSliver(canvas, gw, gh, mapStart, mapSpan, rawMin, rawMax, tares, perf);
  }

  /// First pixel column not covered by the baked image (where the vector
  /// sliver starts). The image blit is clipped here so image and sliver never
  /// double-blend.
  int _sliverStartCol(double gw, int mapStart, int mapSpan) {
    final int gwInt = gw.toInt();
    final double x = (_cache.end - mapStart) * gwInt / mapSpan;
    return x.floor().clamp(0, gwInt);
  }

  /// Draw the baked image under the current mapping.
  ///
  /// Image x-pixel u covers sample s = start + u * span / gw, which today
  /// lands at x = (s - mapStart) * gw / mapSpan = xOffset + u * xScale --
  /// affine, so one drawImageRect repositions the content exactly. Same
  /// derivation vertically from valueToY: y = gh - (v - tare - rawMin) * gh /
  /// range is affine in (rawMin, range) and the per-channel tare cancels out.
  void _blitBaked(
    Canvas canvas,
    double gw,
    double gh,
    int mapStart,
    int mapSpan,
    double rawMin,
    double rawMax,
  ) {
    final c = _cache;
    final img = c.image;
    if (img == null) return;

    final double xScale = c.span / mapSpan;
    final double xOffset = (c.start - mapStart) * gw / mapSpan;
    final double yScale = (c.rawMax - c.rawMin) / (rawMax - rawMin);
    final double yOffset =
        gh * (1 - yScale) + (rawMin - c.rawMin) * gh / (rawMax - rawMin);

    final double xClip = _sliverStartCol(gw, mapStart, mapSpan).toDouble();
    if (xClip <= 0) return;

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, xClip, gh));
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(xOffset, yOffset, gw * xScale, gh * yScale),
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();
  }

  /// Vector-render the columns not covered by the baked image.
  void _drawSliver(
    Canvas canvas,
    double gw,
    double gh,
    int mapStart,
    int mapSpan,
    double rawMin,
    double rawMax,
    List<double> tares,
    EnvelopePerf perf,
  ) {
    final int col = _sliverStartCol(gw, mapStart, mapSpan);
    if (col >= gw.toInt()) return;
    _drawWaveformColumns(
      canvas,
      gw,
      gh,
      mapStart,
      mapSpan,
      rawMin,
      rawMax,
      tares,
      pxFrom: col,
      perf: perf,
    );
  }

  /// Vector-render waveform columns [pxFrom, gw) of the current mapping.
  /// Columns are anchored to the global pixel grid (pxFrom only skips work),
  /// so sliver columns land exactly where a full render would put them.
  void _drawWaveformColumns(
    Canvas canvas,
    double gw,
    double gh,
    int mapStart,
    int mapSpan,
    double rawMin,
    double rawMax,
    List<double> tares, {
    required int pxFrom,
    required EnvelopePerf perf,
  }) {
    final dataRange = rawMax - rawMin;
    final int gwInt = gw.toInt();
    for (int i = 0; i < _activeIndices.length; i++) {
      final ch = _activeIndices[i];
      final tare = tares[i];
      final chColor = _colors[ch % _colors.length];

      drawSqueezedEnvelope(
        canvas,
        data: _data,
        channel: ch,
        pixelWidth: gwInt,
        pxFrom: pxFrom,
        rangeStart: mapStart,
        rangeSpan: mapSpan,
        valueToY: (raw) =>
            (gh - (raw - tare - rawMin) * gh / dataRange).clamp(0.0, gh),
        avgColor: chColor.withAlpha(180),
        envColor: chColor.withAlpha(60),
        perf: perf, // TEMP PERF
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter oldDelegate) {
    // Repaint if any input the paint() method reads has changed. The viewport
    // highlight derives from _ctrl.effectiveRange(), which depends on isLive and
    // liveSpan in addition to viewStart/viewEnd, so all of those must be compared.
    return oldDelegate._data.totalSamples != _data.totalSamples ||
        oldDelegate._data.oldestSample != _data.oldestSample ||
        oldDelegate._ctrl.viewStart != _ctrl.viewStart ||
        oldDelegate._ctrl.viewEnd != _ctrl.viewEnd ||
        oldDelegate._ctrl.isLive != _ctrl.isLive ||
        oldDelegate._ctrl.liveSpan != _ctrl.liveSpan ||
        !listEquals(oldDelegate._activeIndices, _activeIndices) ||
        !listEquals(oldDelegate._colors, _colors);
  }
}
// ---------------------------------------------------------------------------
// Interactive Graph Area (handles gestures)
// ---------------------------------------------------------------------------

class InteractiveGraphArea extends StatefulWidget {
  final GraphDataSource data;
  final GraphController ctrl;
  final Widget child;

  const InteractiveGraphArea({
    super.key,
    required this.data,
    required this.ctrl,
    required this.child,
  });

  @override
  State<InteractiveGraphArea> createState() => _InteractiveGraphAreaState();
}

class _InteractiveGraphAreaState extends State<InteractiveGraphArea> {
  // Gesture tracking
  double? _panStartX;
  int? _panStartSample;
  int? _panEndSample;
  double? _scaleStartSpan;
  double? _pinchFocalX;
  bool _wasLiveOnScaleStart = false;

  void _onScaleStart(ScaleStartDetails details) {
    final total = widget.data.totalSamples;
    if (total == 0) return;

    final (s, e) = widget.ctrl.effectiveRange(
      total,
      widget.data.oldestSample,
      bufferCapacity: widget.data.bufferCapacity,
    );
    _panStartSample = s;
    _panEndSample = e;
    _panStartX = details.localFocalPoint.dx;
    _scaleStartSpan = (e - s).toDouble();
    _pinchFocalX = details.localFocalPoint.dx;
    _wasLiveOnScaleStart = widget.ctrl.isLive;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, double graphWidth) {
    final total = widget.data.totalSamples;
    if (total == 0 || _panStartSample == null || graphWidth <= 0) return;

    final origStart = _panStartSample!;
    final origSpan = _panEndSample! - origStart;
    final oldestSample = widget.data.oldestSample;

    if (details.scale != 1.0 && _scaleStartSpan != null) {
      // Pinch zoom, anchored to the gesture-start window so tracking stays
      // stable while totalSamples grows.
      widget.ctrl.zoomTo(
        (_scaleStartSpan! / details.scale).round(),
        (_pinchFocalX! / graphWidth).clamp(0.0, 1.0),
        baseStart: origStart,
        baseSpan: origSpan,
        anchorLiveEdge: _wasLiveOnScaleStart,
        totalSamples: total,
        oldestSample: oldestSample,
      );
    } else {
      // Pan by the horizontal drag distance, relative to the gesture-start
      // window.
      final dx = details.localFocalPoint.dx - _panStartX!;
      final deltaSamples = -(dx * origSpan / graphWidth).round();
      widget.ctrl.applyWindow(
        origStart + deltaSamples,
        origSpan,
        total,
        oldestSample,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphWidth = graphPlotWidth(constraints.maxWidth);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (e) => _handleGraphPointerScroll(
            e,
            widget.data,
            widget.ctrl,
            graphWidth,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: (d) => _onScaleUpdate(d, graphWidth),
            child: widget.child,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Graph Workspace Widget
// ---------------------------------------------------------------------------

class GraphWorkspace extends StatefulWidget {
  final GraphDataSource data;
  final GraphController ctrl;
  final AppSettings settings;
  final bool showDerivative;
  final bool isLiveGraph;
  final bool showEnvelope;
  final bool showMinimap;

  const GraphWorkspace({
    super.key,
    required this.data,
    required this.ctrl,
    required this.settings,
    this.showDerivative = false,
    this.isLiveGraph = true,
    this.showEnvelope = true,
    this.showMinimap = true,
  });

  @override
  State<GraphWorkspace> createState() => _GraphWorkspaceState();
}

class _GraphWorkspaceState extends State<GraphWorkspace> {
  final GraphLineCache _forceCache = GraphLineCache();
  final GraphLineCache _derivCache = GraphLineCache();

  @override
  void dispose() {
    _forceCache.invalidate();
    _derivCache.invalidate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Column(
              children: [
                // Main force graph
                Expanded(
                  flex: widget.showDerivative ? 6 : 10,
                  child: InteractiveGraphArea(
                    data: widget.data,
                    ctrl: widget.ctrl,
                    child: CustomPaint(
                      foregroundPainter: ForceGraphPainter(
                        widget.data,
                        widget.settings,
                        widget.ctrl,
                        showXLabels: !widget.showDerivative,
                        showEnvelope: widget.showEnvelope,
                        cache: _forceCache,
                        colorScheme: colorScheme,
                        dpr: dpr,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
                // Derivative graph (when enabled)
                if (widget.showDerivative)
                  Expanded(
                    flex: 4,
                    child: InteractiveGraphArea(
                      data: widget.data,
                      ctrl: widget.ctrl,
                      child: CustomPaint(
                        foregroundPainter: DerivativeGraphPainter(
                          widget.data,
                          widget.settings,
                          widget.ctrl,
                          showEnvelope: widget.showEnvelope,
                          cache: _derivCache,
                          colorScheme: colorScheme,
                          dpr: dpr,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                // Minimap
                if (widget.showMinimap)
                  Minimap(
                    dataSource: widget.data,
                    activeChannels: widget.settings.activeChannelIndices,
                    graphCtrl: widget.ctrl,
                    channelColors: widget.settings.activeChannelIndices
                        .map(getChannelColor)
                        .toList(),
                  ),
              ],
            ),
            // LIVE button (appears when not following live edge)
            ListenableBuilder(
              listenable: widget.ctrl,
              builder: (context, _) {
                if (widget.ctrl.isLive ||
                    widget.data.totalSamples == 0 ||
                    !widget.isLiveGraph) {
                  return const SizedBox.shrink();
                }
                return Positioned(
                  right: 64,
                  top: 8,
                  child: FilledButton.tonalIcon(
                    onPressed: () => widget.ctrl.goLive(
                      totalSamples: widget.data.totalSamples,
                      oldestSample: widget.data.oldestSample,
                    ),
                    icon: const Icon(Icons.fast_forward, size: 16),
                    label: const Text('LIVE'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                );
              },
            ),
            // Zoom buttons
            Positioned(
              right: 72,
              bottom: 40,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'zoomIn_${widget.data.hashCode}',
                    onPressed: () {
                      if (widget.data.totalSamples > 0) {
                        final focal = widget.ctrl.isLive ? 1.0 : 0.5;
                        widget.ctrl.zoom(
                          1.2,
                          focal,
                          widget.data.totalSamples,
                          widget.data.oldestSample,
                          widget.data.bufferCapacity,
                        );
                      }
                    },
                    child: const Icon(Icons.zoom_in),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'zoomOut_${widget.data.hashCode}',
                    onPressed: () {
                      if (widget.data.totalSamples > 0) {
                        final focal = widget.ctrl.isLive ? 1.0 : 0.5;
                        widget.ctrl.zoom(
                          1 / 1.2,
                          focal,
                          widget.data.totalSamples,
                          widget.data.oldestSample,
                          widget.data.bufferCapacity,
                        );
                      }
                    },
                    child: const Icon(Icons.zoom_out),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

typedef _ScaleConfigItem = ({int limit, int delta});

const List<_ScaleConfigItem> _xScaleConfig = [
  (limit: 1, delta: 1),
  (limit: 2, delta: 1),
  (limit: 5, delta: 1),
  (limit: 10, delta: 2),
  (limit: 30, delta: 5),
  (limit: 60, delta: 10),
  (limit: 120, delta: 20),
  (limit: 300, delta: 30),
  (limit: 600, delta: 60),
];

_ScaleConfigItem _findScale(double val, List<_ScaleConfigItem> list) {
  return list.firstWhere((e) => val < e.limit, orElse: () => list.last);
}

String _fmtTime(int sec) {
  if (sec < 0) return '-${_fmtTime(-sec)}';
  if (sec < 60) return sec.toString();
  final s = (sec % 60 < 10) ? '0' : '';
  return '${sec ~/ 60}:$s${sec % 60}';
}

/// Format fractional seconds for sub-second X labels.
String _fmtTimeFrac(double sec) {
  if (sec < 0) return '-${_fmtTimeFrac(-sec)}';
  if (sec >= 60) {
    final m = sec ~/ 60;
    final s = sec - m * 60;
    return '$m:${s.toStringAsFixed(1).padLeft(4, '0')}';
  }
  if (sec >= 1) return sec.toStringAsFixed(1);
  return '${(sec * 1000).round()}ms';
}

// Label paragraph cache
final Map<String, ui.Paragraph> _labelCache = HashMap();

ui.Paragraph _prepareLabel(String text, {Color color = Colors.black}) {
  final key = '$text|${color.toARGB32()}';
  return _labelCache.putIfAbsent(key, () {
    final style = ui.TextStyle(color: color, fontSize: 11);
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(textAlign: TextAlign.left, maxLines: 1),
          )
          ..pushStyle(style)
          ..addText(text);
    return builder.build()..layout(const ui.ParagraphConstraints(width: 80));
  });
}

// ---------------------------------------------------------------------------
// Compute nice Y-axis range for data that spans [dataMin, dataMax] in display units.
// Returns (yMin, yMax, tickDelta) where yMin <= 0 <= yMax (if data crosses zero)
// and tickDelta is the spacing between major ticks.
// ---------------------------------------------------------------------------

typedef YAxisRange = ({double yMin, double yMax, double tickDelta});

YAxisRange _computeYRange(double dataMin, double dataMax) {
  // Ensure some minimum range to avoid degenerate axes
  if (dataMax - dataMin < 0.001) {
    dataMax = dataMin + 1.0;
  }

  final range = dataMax - dataMin;

  // Pick a nice tick delta: find the order of magnitude, then use 1/2/5 steps
  final rawStep = range / 5; // aim for ~5 ticks
  final mag = math.pow(10, (math.log(rawStep) / math.ln10).floor()).toDouble();
  double tickDelta;
  if (rawStep / mag < 1.5) {
    tickDelta = mag;
  } else if (rawStep / mag < 3.5) {
    tickDelta = mag * 2;
  } else if (rawStep / mag < 7.5) {
    tickDelta = mag * 5;
  } else {
    tickDelta = mag * 10;
  }

  if (tickDelta < 0.001) tickDelta = 0.001;

  // Snap yMin and yMax to tick boundaries
  final yMin = (dataMin / tickDelta).floor() * tickDelta;
  final yMax = (dataMax / tickDelta).ceil() * tickDelta;

  return (yMin: yMin, yMax: yMax, tickDelta: tickDelta);
}

// ---------------------------------------------------------------------------
// Shared plot toolkit
//
// Small reusable drawing primitives used by every graph painter (force,
// derivative, and future X-Y / FFT plots). Keeping them as free functions lets
// new plot types reuse axis and envelope rendering instead of copy-pasting.
// ---------------------------------------------------------------------------

/// Append vertical X-axis grid lines (and optional time labels) for the visible
/// window [viewStart, viewEnd) to [grid]. Handles both sub-second and >=1s
/// scales. When [drawMinor] is true, half-delta minor lines are added too.
void drawTimeAxis(
  Canvas canvas,
  Path grid,
  Size graphSz, {
  required int viewStart,
  required int viewEnd,
  required int oldestSample,
  required int sampleRate,
  required bool showLabels,
  bool drawMinor = false,
  Color textColor = Colors.black,
}) {
  final viewSamples = viewEnd - viewStart;
  if (viewSamples <= 0) return;

  double xOf(double sec, double startSec) =>
      (sec - startSec) * sampleRate * graphSz.width / viewSamples;

  void vline(double xPos, String? label) {
    grid.moveTo(xPos, 0);
    grid.lineTo(xPos, graphSz.height);
    if (label != null) {
      final par = _prepareLabel(label, color: textColor);
      canvas.drawParagraph(
        par,
        Offset(xPos - par.longestLine / 2, graphSz.height + 2),
      );
    }
  }

  final double xSpanSec = viewSamples / sampleRate;

  if (xSpanSec < 1.0) {
    // Sub-second: fractional labels relative to the oldest sample.
    final niceStepMs = _niceNum(xSpanSec * 1000 / 5); // aim for ~5 labels
    final startSec = (viewStart - oldestSample) / sampleRate;
    final endMs = ((viewEnd - oldestSample) / sampleRate) * 1000;
    final firstTickMs = (startSec * 1000 / niceStepMs).ceil() * niceStepMs;
    for (double tMs = firstTickMs; tMs < endMs; tMs += niceStepMs) {
      final tSec = tMs / 1000;
      vline(xOf(tSec, startSec), showLabels ? _fmtTimeFrac(tSec) : null);
    }
  } else {
    final xC = _findScale(xSpanSec, _xScaleConfig);
    final startSec = viewStart / sampleRate;
    final endSec = viewEnd / sampleRate;

    final int firstTick = ((startSec / xC.delta).ceil() * xC.delta).toInt();
    for (int sec = firstTick; sec.toDouble() < endSec; sec += xC.delta) {
      vline(xOf(sec.toDouble(), startSec), showLabels ? _fmtTime(sec) : null);
    }

    if (drawMinor) {
      final minorDeltaSec = xC.delta / 2;
      final firstMinor = (startSec / minorDeltaSec).ceil() * minorDeltaSec;
      for (double sec = firstMinor; sec < endSec; sec += minorDeltaSec) {
        vline(xOf(sec, startSec), null);
      }
    }
  }
}

/// Append horizontal Y-axis grid lines and labels (formatted by [labelFor]) for
/// [yRange] to [grid]. When [drawMinor] is true, half-delta minor lines are
/// added. [valueToY] maps an axis value to a pixel Y.
void drawValueAxis(
  Canvas canvas,
  Path grid,
  Size graphSz,
  YAxisRange yRange,
  double Function(double value) valueToY, {
  required String Function(double tick) labelFor,
  bool drawMinor = false,
  Color textColor = Colors.black,
}) {
  final delta = yRange.tickDelta;
  for (
    double tick = (yRange.yMin / delta).ceil() * delta;
    tick <= yRange.yMax + delta * 0.01;
    tick += delta
  ) {
    final yPos = valueToY(tick);
    if (yPos >= -1 && yPos <= graphSz.height + 1) {
      grid.moveTo(0, yPos);
      grid.lineTo(graphSz.width, yPos);
      final par = _prepareLabel(labelFor(tick), color: textColor);
      canvas.drawParagraph(
        par,
        Offset(graphSz.width + 4, yPos - par.height / 2),
      );
    }
  }

  if (drawMinor) {
    final minorDelta = delta / 2;
    for (
      double tick = (yRange.yMin / minorDelta).ceil() * minorDelta;
      tick <= yRange.yMax + minorDelta * 0.01;
      tick += minorDelta
    ) {
      final yPos = valueToY(tick);
      if (yPos >= -1 && yPos <= graphSz.height + 1) {
        grid.moveTo(0, yPos);
        grid.lineTo(graphSz.width, yPos);
      }
    }
  }
}

/// Draw a horizontal zero baseline if the axis range crosses zero.
void drawZeroBaseline(
  Canvas canvas,
  Size graphSz,
  YAxisRange yRange,
  double Function(double value) valueToY,
  Color color,
) {
  if (yRange.yMin < 0 && yRange.yMax > 0) {
    final zeroY = valueToY(0);
    canvas.drawLine(
      Offset(0, zeroY),
      Offset(graphSz.width, zeroY),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
  }
}

/// Draws a diagonal warning hatch pattern in regions where data is missing (sentinel value).
void drawMissingDataHatching(
  Canvas canvas,
  Size graphSz, {
  required int viewStart,
  required int viewEnd,
  required GraphDataSource data,
  required Color color,
}) {
  final totalSamples = data.totalSamples;
  final oldestSample = data.oldestSample;
  final sScanStart = math.max(viewStart, oldestSample);
  final sScanEnd = math.min(viewEnd, totalSamples);
  if (sScanStart >= sScanEnd) return;

  // We only need to check channel 0 since dropped packets are dropped for all channels simultaneously.
  final line = data.channel(0).data;
  final bufferCap = data.bufferCapacity;

  final viewSamples = viewEnd - viewStart;
  if (viewSamples <= 0) return;

  double xOf(int sampleIdx) =>
      (sampleIdx - viewStart) * graphSz.width / viewSamples;

  int gapStart = -1;

  void drawHatchRegion(int startIdx, int endIdx) {
    final xStart = xOf(startIdx);
    final xEnd = xOf(endIdx);

    // Draw the hatch pattern
    final pen = Paint()
      ..color = color.withAlpha(60)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Hatch line spacing
    const double spacing = 8.0;

    // Draw diagonals from bottom-left to top-right
    final cStart = xStart - graphSz.height;
    final cEnd = xEnd;

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(xStart, 0, xEnd, graphSz.height));

    for (
      double c = (cStart / spacing).floor() * spacing;
      c <= cEnd;
      c += spacing
    ) {
      canvas.drawLine(
        Offset(c, graphSz.height),
        Offset(c + graphSz.height, 0),
        pen,
      );
    }

    // Also draw a light background fill to make it pop
    final bgPen = Paint()
      ..color = color.withAlpha(20)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTRB(xStart, 0, xEnd, graphSz.height), bgPen);

    canvas.restore();
  }

  for (int i = sScanStart; i < sScanEnd; i++) {
    final rawVal = line[i % bufferCap];
    if (data.missingSampleSentinel != null &&
        rawVal == data.missingSampleSentinel) {
      if (gapStart == -1) {
        gapStart = i;
      }
    } else {
      if (gapStart != -1) {
        drawHatchRegion(gapStart, i);
        gapStart = -1;
      }
    }
  }

  if (gapStart != -1) {
    drawHatchRegion(gapStart, sScanEnd);
  }
}

/// Accumulates 2D vertices into a fixed [Float32List] and flushes them in
/// bounded chunks, staying within the web (Skwasm/Emscripten) stack-allocation
/// limit of 4096 floats per draw call.
///
/// On flush, the trailing [preserveFloats] floats are carried over to the front
/// of the buffer so a continuous primitive (triangle strip or polyline) is not
/// broken across flushes. [drawThreshold] is the minimum filled-float count
/// required before a flush actually emits anything.
///
/// NOTE: this batching only exists for the web stack limit; with the current
/// architecture it can eventually be removed once that limit is lifted/tested.
class VertexBatcher {
  VertexBatcher({
    required this.preserveFloats,
    required this.drawThreshold,
    required this.onFlush,
    int capacity = 4096,
  }) : _buf = Float32List(capacity);

  final Float32List _buf;
  final int preserveFloats;
  final int drawThreshold;

  /// Draws the populated `[0, length)` view of the backing buffer.
  final void Function(Float32List view) onFlush;

  int _len = 0;

  /// Remaining capacity before a flush is forced.
  int get _capacity => _buf.length;

  /// Append a single (x, y) vertex.
  void add(double x, double y) {
    _buf[_len++] = x;
    _buf[_len++] = y;
  }

  /// Whether [extraFloats] more floats would overflow the buffer.
  bool wouldOverflow(int extraFloats) => _len + extraFloats > _capacity;

  /// Emit the accumulated vertices (if past [drawThreshold]) and reset, keeping
  /// the trailing [preserveFloats] floats so the primitive stays continuous.
  void flush() {
    if (_len > drawThreshold) {
      onFlush(Float32List.sublistView(_buf, 0, _len));
      for (int i = 0; i < preserveFloats; i++) {
        _buf[i] = _buf[_len - preserveFloats + i];
      }
      _len = preserveFloats;
    }
  }
}

// TEMP PERF (remove after profiling): timing sink threaded through the
// squeeze-envelope renderer so the minimap can report reduction-loop time and
// canvas-draw time separately.
class EnvelopePerf {
  final Stopwatch sw = Stopwatch()..start();
  int loopMicros = 0;
  int drawMicros = 0;
}

/// The (average polyline, min/max envelope fill) [VertexBatcher] pair shared
/// by the envelope renderers. Both batchers reuse one [Paint], restyled per
/// flush.
({VertexBatcher avg, VertexBatcher env}) _envelopeBatchers(
  Canvas canvas, {
  required Color avgColor,
  required double avgStrokeWidth,
  required Color envColor,
  EnvelopePerf? perf,
}) {
  final pen = Paint();

  final avg = VertexBatcher(
    preserveFloats: 2,
    drawThreshold: 2,
    onFlush: (view) {
      pen
        ..color = avgColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = avgStrokeWidth;
      final start = perf?.sw.elapsedMicroseconds;
      canvas.drawRawPoints(ui.PointMode.polygon, view, pen);
      if (start != null) {
        perf!.drawMicros += perf.sw.elapsedMicroseconds - start;
      }
    },
  );

  final env = VertexBatcher(
    preserveFloats: 4,
    drawThreshold: 4,
    onFlush: (view) {
      final vertices = ui.Vertices.raw(ui.VertexMode.triangleStrip, view);
      pen
        ..color = envColor
        ..style = PaintingStyle.fill;
      final start = perf?.sw.elapsedMicroseconds;
      canvas.drawVertices(vertices, ui.BlendMode.srcOver, pen);
      if (start != null) {
        perf!.drawMicros += perf.sw.elapsedMicroseconds - start;
      }
      vertices.dispose();
    },
  );

  return (avg: avg, env: env);
}

/// Render one channel as a min/avg/max envelope across [graphW] pixel columns.
///
/// For each pixel column the samples mapped to it are reduced to min/avg/max via
/// [sampleAt] (raw per-sample value), then projected with [valueToY]. The shaded
/// envelope is filled at low alpha and the average is stroked on top.
///
/// Blocks are anchored to absolute sample indices so the geometry is
/// tile-cacheable (slide mode); [drawSqueezedEnvelope] is the squeeze-mode
/// counterpart.
///
/// Vertices are flushed in <=4096-float chunks to stay within the web
/// (Skwasm/Emscripten) stack-allocation limit.
void drawChannelEnvelope(
  Canvas canvas, {
  required Color color,
  required double graphW,
  required int viewStart,
  required int viewSamples,
  required int oldestSample,
  required int totalSamples,
  required int firstUsableSample,
  required double Function(int sampleIndex) sampleAt,
  required double Function(double rawReduced) valueToY,
  bool showEnvelope = true,
  int? clipEnvelopeSamples,
}) {
  final (avg: avg, env: env) = _envelopeBatchers(
    canvas,
    avgColor: color,
    avgStrokeWidth: 1.5,
    envColor: color.withAlpha(60),
  );

  // Calculate alignment block size
  final int blockSize = blockSizeFor(viewSamples, graphW);

  // Blocks are anchored to absolute sample 0 (sStart = k * blockSize), NOT to
  // viewStart. This is what lets a block fall on the same pixels regardless of
  // scroll, so paintCachedChannels can record it once and reuse it.
  final int startBlock = (math.max(viewStart, firstUsableSample) / blockSize)
      .floor();
  final int endBlock = (totalSamples / blockSize).ceil();
  final int envelopeLimit = clipEnvelopeSamples ?? totalSamples;

  for (int k = startBlock; k < endBlock; k++) {
    final int sStart = k * blockSize;
    final int sEnd = math.min(
      sStart + blockSize,
      totalSamples,
    ); // last block may be short

    final int drawStart = math.max(sStart, firstUsableSample);
    if (drawStart >= sEnd) continue;
    // sEnd - drawStart in [1, blockSize]; the full-blockSize case is the common
    // one, but do NOT assert it: the trailing block and a block clipped by
    // firstUsableSample are both legitimately shorter.
    assert(sEnd - drawStart >= 1 && sEnd - drawStart <= blockSize);

    double total = 0;
    double minRaw = double.infinity;
    double maxRaw = double.negativeInfinity;
    int validSamples = 0;

    for (int j = drawStart; j < sEnd; j++) {
      final v = sampleAt(j);
      if (v.isNaN) continue;
      total += v;
      if (v < minRaw) minRaw = v;
      if (v > maxRaw) maxRaw = v;
      validSamples++;
    }

    if (validSamples == 0) {
      // Entire block is dropped samples. Break the polyline.
      if (showEnvelope) env.flush();
      avg.flush();
      continue;
    }

    final avgVal = total / validSamples;

    final avgY = valueToY(avgVal);
    final minY = valueToY(minRaw);
    final maxY = valueToY(maxRaw);

    // Absolute X (in this canvas's local space): a cached tile passes its own
    // start as viewStart, so xPos is tile-local and the tile slides as a whole.
    final double xPos = (sStart - viewStart) * graphW / viewSamples;
    final double nextXPos = (sEnd - viewStart) * graphW / viewSamples;

    avg.add(xPos, avgY);

    if (showEnvelope && sStart < envelopeLimit) {
      env.add(xPos, maxY);
      env.add(xPos, minY);
      env.add(nextXPos, maxY);
      env.add(nextXPos, minY);

      if (env.wouldOverflow(8)) env.flush();
    }

    if (avg.wouldOverflow(2)) avg.flush();
  }

  if (showEnvelope) env.flush();
  avg.flush();
}

/// Render one channel as a min/avg/max envelope with one block per pixel
/// column, squeezing the sample range [rangeStart, rangeStart + rangeSpan)
/// into [pixelWidth] columns.
///
/// This is the squeeze-mode counterpart of [drawChannelEnvelope]: the whole
/// history is in view, so the x-mapping of every sample changes as data
/// arrives and the geometry is recomputed every frame instead of tile-cached.
/// Columns spanning many samples aggregate from the channel's precomputed
/// bucket arrays; columns spanning few (zoomed in past ~2 buckets/column)
/// loop the raw ring buffer to avoid blockiness.
///
/// Reduction happens in raw counts; [valueToY] projects a reduced raw value
/// (not tare-subtracted) to a pixel Y.
///
/// [pxFrom] skips columns before it without changing the column->sample grid
/// (columns stay anchored to the full [pixelWidth] mapping), so a partial
/// render (e.g. the minimap's fresh-data sliver) lands exactly where a full
/// render would put it.
void drawSqueezedEnvelope(
  Canvas canvas, {
  required GraphDataSource data,
  required int channel,
  required int pixelWidth,
  required int rangeStart,
  required int rangeSpan,
  required double Function(double raw) valueToY,
  required Color avgColor,
  required Color envColor,
  double avgStrokeWidth = 1.0,
  int pxFrom = 0,
  EnvelopePerf? perf, // TEMP PERF
}) {
  final series = data.channel(channel);
  final line = series.data;
  if (line.isEmpty) return;

  final bufferCapacity = data.bufferCapacity;
  final totalSamples = data.totalSamples;
  final oldestSample = data.oldestSample;
  final sentinel = data.missingSampleSentinel;

  final (avg: avg, env: env) = _envelopeBatchers(
    canvas,
    avgColor: avgColor,
    avgStrokeWidth: avgStrokeWidth,
    envColor: envColor,
    perf: perf,
  );

  final int bucketSize = series.bucketSize;
  final bucketMins = series.bucketMins;
  final bucketMaxs = series.bucketMaxs;
  final bucketSums = series.bucketSums;
  final int numBuckets = bucketMins.length;

  for (int px = pxFrom; px < pixelWidth; px++) {
    final int sStart = rangeStart + px * rangeSpan ~/ pixelWidth;
    final int sEnd = rangeStart + (px + 1) * rangeSpan ~/ pixelWidth;
    final int drawStart = math.max(sStart, oldestSample);
    final int drawEnd = math.min(sEnd, totalSamples);

    if (drawStart >= drawEnd) continue;

    double total = 0;
    double minRaw = double.infinity;
    double maxRaw = double.negativeInfinity;
    int validSamples = 0;

    final int samplesInPixel = drawEnd - drawStart;

    final loopStart = perf?.sw.elapsedMicroseconds; // TEMP PERF

    if (samplesInPixel <= bucketSize * 2) {
      // High-res mode: loop the raw array to avoid blockiness when zoomed
      // in. Honors the dropped-sample sentinel so gaps don't skew the plot.
      for (int j = drawStart; j < drawEnd; j++) {
        final val = line[j % bufferCapacity];
        if (sentinel != null && val == sentinel) {
          continue;
        }
        final valDouble = val.toDouble();
        total += valDouble;
        if (valDouble < minRaw) minRaw = valDouble;
        if (valDouble > maxRaw) maxRaw = valDouble;
        validSamples++;
      }
    } else {
      // Squished mode: aggregate from the precomputed bucket arrays.
      // Sentinels are already excluded from the buckets at ingest time.
      final int bStart = drawStart ~/ bucketSize;
      final int bEnd = drawEnd ~/ bucketSize;

      for (int b = bStart; b <= bEnd; b++) {
        final int listIdx = b % numBuckets;

        final double bMin = bucketMins[listIdx].toDouble();
        final double bMax = bucketMaxs[listIdx].toDouble();
        if (bMin < minRaw) minRaw = bMin;
        if (bMax > maxRaw) maxRaw = bMax;

        int count = bucketSize;
        if (b == bStart) {
          // Only count the covered portion of the first bucket.
          final int bucketEndSample = (b + 1) * bucketSize;
          count = bucketEndSample - drawStart;
          if (count > bucketSize) count = bucketSize;
        } else if (b == bEnd) {
          // Only count the covered portion of the last bucket.
          final int bucketStartSample = b * bucketSize;
          count = drawEnd - bucketStartSample;
          if (count > bucketSize) count = bucketSize;
        }
        if (count < 0) count = 0;

        // Approximate the sum contribution of the covered portion.
        final double avgOfBucket = bucketSums[listIdx] / bucketSize;
        total += avgOfBucket * count;
        validSamples += count;
      }
    }

    if (loopStart != null) {
      perf!.loopMicros += perf.sw.elapsedMicroseconds - loopStart; // TEMP PERF
    }

    if (validSamples == 0) {
      // Entire column is dropped samples. Break the polyline.
      env.flush();
      avg.flush();
      continue;
    }

    final avgY = valueToY(total / validSamples);
    final minY = valueToY(minRaw);
    final maxY = valueToY(maxRaw);

    final xPos = px.toDouble();
    avg.add(xPos, avgY);

    env.add(xPos, maxY);
    env.add(xPos, minY);

    // Flush chunks if we are getting close to the array limits
    if (env.wouldOverflow(4)) env.flush();
    if (avg.wouldOverflow(2)) avg.flush();
  }

  // Flush remaining data
  env.flush();
  avg.flush();
}

/// Blit filter for cached tile images. [FilterQuality.low] (bilinear) hides
/// the fractional-pixel offsets tiles land on while sliding; flip to
/// [FilterQuality.none] to A/B sharpness.
const FilterQuality kTileImageFilterQuality = FilterQuality.low;

/// Padding (logical px) baked around a tile image so AA stroke bleed and the
/// one-block polyline overshoot past the tile edge are not clipped. The
/// horizontal pad additionally covers one block width (see
/// [paintCachedChannels]), which exceeds this when zoomed in past 1 sample/px.
const double kTileImagePad = 4;

/// Max tiles converted to [ui.Image] per frame. A pan/zoom into uncached
/// territory can miss ~13 tiles at once; capping spreads the toImageSync cost
/// (~1-2ms UI-thread each) over a few frames. Overflow tiles are drawn as
/// plain pictures this frame and retried on the next one.
const int kMaxTileImagesPerFrame = 3;

/// Cached tiles more than this many tiles outside the view are evicted.
/// Bitmap tiles are ~0.5-2MB each, so the cache cannot be unbounded the way
/// the picture cache was.
const int kTileEvictionMargin = 8;

/// Draws a graph's data layer using the chunked tile cache.
///
/// The visible window is split into fixed sample-count tiles. Each tile is
/// recorded once (in its own local coordinate space, as if the tile's start
/// were the view start), rasterized once into a [ui.Image], and then blitted
/// at the right screen offset. Panning at constant zoom reuses tile images; a
/// changed [config] (zoom, size, Y-range, tares, dpr) drops the whole cache.
///
/// Only tiles that are fully populated (entirely between [oldestSample] and
/// [totalSamples]) are cached; the live edge and the buffer's trailing edge
/// are re-recorded every frame as plain [ui.Picture]s so they never go stale.
///
/// [drawChunk] is invoked to record one tile. It receives the tile's canvas,
/// the tile's absolute start sample (used as the local view start), and
/// [limitSamples] (one block past the tile end, so the average polyline joins
/// the next tile without a gap). [drawChunk] should clip its envelope fill to
/// [chunkEndSample] to avoid double-blending across tile seams.
///
/// All sample arguments ([viewStart], [viewEnd], ...) are absolute sample
/// indices (the monotonic clock), not buffer slots or pixels; the window is the
/// half-open range [viewStart, viewEnd). Invariant within one cache generation:
/// a sample's tile is `sample ~/ chunkSamples`, a pure function of its index, so
/// a sample never migrates between tiles. Re-tiling only happens together with a
/// full cache clear (config change), which is why a recorded tile is safe to keep.
void paintCachedChannels(
  Canvas canvas,
  GraphLineCache cache,
  CacheConfig config, {
  required int viewStart,
  required int viewEnd,
  required int totalSamples,
  required int oldestSample,
  required double graphW,
  required void Function(
    Canvas chunkCanvas,
    int chunkStartSample,
    int chunkEndSample,
    int limitSamples,
  )
  drawChunk,
}) {
  final int viewSamples = config.viewSamples;
  final int blockSize = blockSizeFor(viewSamples, graphW);

  if (cache.config == null || !cache.config!.matches(config)) {
    cache.invalidate();
    cache.config = config;
    cache.chunkSamples = chunkSamplesFor(viewSamples / graphW, blockSize);
  } else {
    cache.stableFrames++;
  }
  assert(
    cache.chunkSamples % blockSize == 0,
  ); // tiles tile the block grid exactly

  // `~/` truncates toward zero. For viewStart >= 0, startChunk's tile begins at
  // or LEFT of viewStart. If viewStart < 0 (empty space before the first sample),
  // it truncates *up* toward zero, so the first tile begins RIGHT of viewStart.
  // In both cases, the loop covers all populated tiles that overlap the view.
  final int startChunk = viewStart ~/ cache.chunkSamples;
  final int endChunk = (viewEnd - 1) ~/ cache.chunkSamples;

  // Tile width in logical pixels (fractional in general).
  final double tileW = cache.chunkSamples * graphW / viewSamples;
  final double dpr = config.dpr;

  // The recorded polyline overshoots the tile's right edge by one block
  // (limitSamples joins it to the next tile), and one block can be many px
  // when zoomed in past 1 sample/px -- the horizontal pad must cover it.
  // Derived purely from the config, so it is identical on every frame of one
  // cache generation (creation and blit must agree).
  final double hPad = math.max(
    kTileImagePad,
    blockSize * graphW / viewSamples + 2,
  );
  const double vPad = kTileImagePad;

  int imagesCreated = 0;

  for (int c = startChunk; c <= endChunk; c++) {
    final int chunkStartSample = c * cache.chunkSamples;
    final int chunkEndSample = chunkStartSample + cache.chunkSamples;

    // Only fully-buffered tiles are cached. The live edge (chunkEndSample past
    // totalSamples) and the trailing edge (chunkStartSample below oldestSample)
    // change every frame, so they are re-recorded and never stored.
    final bool isFullyPopulated =
        chunkEndSample <= totalSamples && chunkStartSample >= oldestSample;
    // NB: do NOT assert chunkStartSample >= viewStart (false for startChunk) nor
    // >= oldestSample (false for the leftmost tile) -- that's exactly the case
    // isFullyPopulated guards against.

    // The tile was recorded with chunkStartSample as its local origin, so shift
    // it bodily into place; cached tiles only ever differ by this offset.
    final double xOffset =
        (chunkStartSample - viewStart) * graphW / viewSamples;
    // chunkStart can be left OR right of viewStart: ~/ truncates toward zero, so for
    // negative viewStart (large minLiveSpan on a nearly-empty buffer) the first tile
    // starts right of viewStart and xOffset > 0. So no sign guarantee on xOffset.
    assert(
      chunkEndSample > viewStart && chunkStartSample < viewEnd,
    ); // tile overlaps view

    ui.Image? img = cache.images[c];
    ui.Picture? pic;

    if (img == null) {
      // Record the tile. Cacheable tiles are recorded with a padding
      // translate so stroke AA and the one-block overshoot survive the image
      // crop; live/trailing tiles are recorded pad-free and drawn directly.
      final bool tryImage =
          isFullyPopulated &&
          cache.stableFrames >= 2 &&
          imagesCreated < kMaxTileImagesPerFrame;

      final recorder = ui.PictureRecorder();
      final cCanvas = Canvas(recorder);
      if (tryImage) {
        cCanvas.scale(dpr);
        cCanvas.translate(hPad, vPad);
      }

      final int limitSamples = math.min(
        chunkEndSample + blockSize,
        totalSamples,
      );
      drawChunk(cCanvas, chunkStartSample, chunkEndSample, limitSamples);

      pic = recorder.endRecording();
      if (tryImage) {
        img = pic.toImageSync(
          ((tileW + 2 * hPad) * dpr).ceil(),
          ((config.graphH + 2 * vPad) * dpr).ceil(),
        );
        pic.dispose();
        pic = null;
        cache.images[c] = img;
        imagesCreated++;
        PerfStats.addTileImaged(); // TEMP PERF
      }
    }

    canvas.save();
    canvas.translate(xOffset, 0);
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(-hPad, -vPad, img.width / dpr, img.height / dpr),
        Paint()..filterQuality = kTileImageFilterQuality,
      );
      PerfStats.addTile(TileDraw.blit); // TEMP PERF
    } else {
      canvas.drawPicture(pic!);
      PerfStats.addTile(
        isFullyPopulated ? TileDraw.recorded : TileDraw.live,
      ); // TEMP PERF
    }
    canvas.restore();
  }

  // Evict cached tiles far outside the view; bitmap tiles are too big to keep
  // unboundedly (the picture cache could get away with it).
  cache.images.removeWhere((c, img) {
    if (c >= startChunk - kTileEvictionMargin &&
        c <= endChunk + kTileEvictionMargin) {
      return false;
    }
    img.dispose();
    return true;
  });
}

// ---------------------------------------------------------------------------
// Windowed time-series graph painters (force, derivative)
// ---------------------------------------------------------------------------

/// Common painter prologue shared by the force and derivative graphs: translate
/// into the plot area, compute the plot [Size], draw the frame border, and
/// resolve the visible window.
///
/// Returns null when there is nothing to draw (degenerate size, too few
/// samples, or a degenerate window). [minSamples] is the smallest sample count
/// the graph needs (1 for force, 2 for the derivative's first difference).
typedef _GraphLayout = ({
  Size graphSz,
  int viewStart,
  int viewEnd,
  int viewSamples,
});

_GraphLayout? _setupGraphFrame(
  Canvas canvas,
  Size size,
  GraphDataSource data,
  GraphController ctrl, {
  required double topSpace,
  required double bottomSpace,
  required int minSamples,
  required Color frameColor,
}) {
  final pen = Paint()
    ..color = frameColor
    ..style = PaintingStyle.stroke;

  canvas.translate(kGraphLeftSpace, topSpace);
  final graphSz = Size(
    size.width - kGraphLeftSpace - kGraphRightSpace,
    size.height - bottomSpace - topSpace,
  );

  if (graphSz.width <= 0 || graphSz.height <= 0) return null;

  canvas.drawRect(
    Rect.fromLTRB(0, 0, graphSz.width, graphSz.height),
    pen..strokeWidth = 0.5,
  );

  if (data.totalSamples < minSamples) return null;

  final (viewStart, viewEnd) = ctrl.effectiveRange(
    data.totalSamples,
    data.oldestSample,
    bufferCapacity: data.bufferCapacity,
  );
  final viewSamples = viewEnd - viewStart;
  if (viewSamples < minSamples) return null;

  return (
    graphSz: graphSz,
    viewStart: viewStart,
    viewEnd: viewEnd,
    viewSamples: viewSamples,
  );
}

// ---------------------------------------------------------------------------
// TEMP PERF INSTRUMENTATION (remove after profiling)
//
// Aggregates two independent measurements and prints them together every
// [_reportEvery] frames:
//   * Dart paint time   -- time the UI thread spends in the time-series
//                          painters' paint (force + derivative) building the
//                          draw calls (recorded via [addPaint]).
//   * Skwasm raster time -- FrameTiming.rasterDuration, the worker/GPU thread
//                          time to execute the recorded display list.
//   * Build time         -- FrameTiming.buildDuration, for context.
// Frame timings are fed in via SchedulerBinding.addTimingsCallback (see
// _LiveTabState); the report is emitted from there once 60 frames accrue.
// ---------------------------------------------------------------------------
class PerfStats {
  static const int _reportEvery = 60;

  // Dart paint accumulation (UI thread).
  static int _paintCount = 0;
  static int _paintMicros = 0;

  static int _minimapCount = 0;
  static int _minimapMicros = 0;
  static int _minimapLoopMicros = 0;
  static int _minimapDrawMicros = 0;

  /// Record one _TimeSeriesGraphPainter.paint() duration.
  static void addPaint(int micros) {
    _paintMicros += micros;
    _paintCount++;
  }

  static void addMinimapPaint(int total, int loop, int draw) {
    _minimapCount++;
    _minimapMicros += total;
    _minimapLoopMicros += loop;
    _minimapDrawMicros += draw;
  }

  // Minimap affine-reuse bake accounting.
  static int _minimapIncBakes = 0;
  static int _minimapFullBakes = 0;

  /// Record one minimap image rebake (incremental or full vector).
  static void addMinimapBake({required bool full}) {
    if (full) {
      _minimapFullBakes++;
    } else {
      _minimapIncBakes++;
    }
  }

  // Tile accounting for paintCachedChannels (see TileDraw).
  static int _tilesBlit = 0;
  static int _tilesLive = 0;
  static int _tilesRecorded = 0;
  static int _tilesImaged = 0;

  /// Record how one tile was drawn this frame. Imaged tiles count as both
  /// created ([_tilesImaged]) and blitted.
  static void addTile(TileDraw kind) {
    switch (kind) {
      case TileDraw.blit:
        _tilesBlit++;
      case TileDraw.live:
        _tilesLive++;
      case TileDraw.recorded:
        _tilesRecorded++;
    }
  }

  /// Record one ui.Image tile creation (toImageSync).
  static void addTileImaged() => _tilesImaged++;

  /// Feed one frame's timing. Emits a combined report every 60 frames.
  static void addFrame(int rasterMicros, int buildMicros) {
    _rasterMicros += rasterMicros;
    _buildMicros += buildMicros;
    _frameCount++;
    if (_frameCount >= _reportEvery) _report();
  }

  static int _frameCount = 0;
  static int _rasterMicros = 0;
  static int _buildMicros = 0;

  static void _report() {
    final dartAvg = _paintCount > 0 ? _paintMicros / _paintCount : 0;
    final mmAvg = _minimapCount > 0 ? _minimapMicros / _minimapCount : 0;
    final mmLoopAvg = _minimapCount > 0
        ? _minimapLoopMicros / _minimapCount
        : 0;
    final mmDrawAvg = _minimapCount > 0
        ? _minimapDrawMicros / _minimapCount
        : 0;
    final rasterAvg = _frameCount > 0 ? _rasterMicros / _frameCount : 0;
    final buildAvg = _frameCount > 0 ? _buildMicros / _frameCount : 0;
    final fc = _frameCount > 0 ? _frameCount : 1;
    debugPrint(
      '[PERF] over $_frameCount frames | '
      'Main paint: ${dartAvg.toStringAsFixed(0)}us (${_paintCount}x) | '
      'Minimap: ${mmAvg.toStringAsFixed(0)}us (loop: ${mmLoopAvg.toStringAsFixed(0)}us, draw: ${mmDrawAvg.toStringAsFixed(0)}us, bakes: ${_minimapIncBakes}i+${_minimapFullBakes}f) | '
      'tiles/frame: ${(_tilesBlit / fc).toStringAsFixed(1)} blit, '
      '${(_tilesLive / fc).toStringAsFixed(1)} live, '
      '${(_tilesRecorded / fc).toStringAsFixed(1)} recorded '
      '($_tilesImaged imaged) | '
      'Skwasm raster: ${rasterAvg.toStringAsFixed(0)}us | '
      'build: ${buildAvg.toStringAsFixed(0)}us',
    );
    _paintCount = 0;
    _paintMicros = 0;
    _minimapCount = 0;
    _minimapMicros = 0;
    _minimapLoopMicros = 0;
    _minimapDrawMicros = 0;
    _minimapIncBakes = 0;
    _minimapFullBakes = 0;
    _tilesBlit = 0;
    _tilesLive = 0;
    _tilesRecorded = 0;
    _tilesImaged = 0;
    _frameCount = 0;
    _rasterMicros = 0;
    _buildMicros = 0;
  }
}

/// TEMP PERF: how a tile got onto the screen this frame.
///   * blit     -- cached ui.Image drawn via drawImageRect (the cheap path)
///   * live     -- live/trailing-edge tile, re-recorded picture (expected ~1/frame)
///   * recorded -- fully-populated tile drawn as a fresh picture (image
///                 creation deferred by the stability gate or per-frame cap)
enum TileDraw { blit, live, recorded }

/// Shared engine for the windowed time-series graphs (force, derivative).
///
/// Handles the pipeline common to both: frame setup, Y-range for the visible
/// window, axes/grid, zero baseline, missing-data hatching, and the
/// tile-cached envelope rendering. Subclasses define the series being
/// plotted -- [sampleAt] (per-channel value in display units), [computeYRange],
/// [yTickLabel] -- plus layout tweaks and cache-key extras.
abstract class _TimeSeriesGraphPainter extends CustomPainter {
  final GraphDataSource _data;
  final AppSettings _settings;
  final GraphController _ctrl;
  final bool showEnvelope;
  final GraphLineCache cache;
  final ColorScheme colorScheme;

  /// Device pixel ratio used when rasterizing tile images.
  final double dpr;

  _TimeSeriesGraphPainter(
    this._data,
    this._settings,
    this._ctrl, {
    this.showEnvelope = true,
    required this.cache,
    required this.colorScheme,
    required this.dpr,
  }) : super(repaint: Listenable.merge([_data.repaint, _ctrl]));

  // --- Layout hooks --------------------------------------------------------

  /// Padding above the plot area.
  double get topSpace;

  /// Whether to draw time labels below the X axis.
  bool get showXLabels => true;

  /// Whether to add half-delta minor grid lines on both axes.
  bool get drawMinorGrid => false;

  /// Offset from [GraphDataSource.oldestSample] of the first sample the
  /// series can be evaluated at (1 for a first difference).
  int get firstSampleOffset => 0;

  // --- Series hooks --------------------------------------------------------

  /// Returns the series evaluator for [channel]: the value at an absolute
  /// sample index, in display units. NaN marks a missing sample.
  double Function(int j) sampleAt(int channel);

  /// Y-axis range (display units) for the visible window.
  YAxisRange computeYRange(int viewStart, int viewEnd);

  /// Label for a Y-axis tick.
  String yTickLabel(double tick);

  /// Per-channel values mixed into the tile-cache key; return the tares when
  /// the series depends on them.
  List<double> cacheKeyTares() => const [];

  /// Optional chrome drawn after the axes, before the data lines.
  void drawOverlay(Canvas canvas, Size graphSz) {}

  @override
  void paint(Canvas canvas, Size size) {
    // TEMP PERF: measure Dart-side draw-call construction time (UI thread).
    final sw = Stopwatch()..start();
    try {
      _paint(canvas, size);
    } finally {
      sw.stop();
      PerfStats.addPaint(sw.elapsedMicroseconds);
    }
  }

  void _paint(Canvas canvas, Size size) {
    final layout = _setupGraphFrame(
      canvas,
      size,
      _data,
      _ctrl,
      topSpace: topSpace,
      bottomSpace: showXLabels ? kGraphBottomSpace : 4,
      minSamples: 1 + firstSampleOffset,
      frameColor: colorScheme.primary.withAlpha(150),
    );
    if (layout == null) return;

    final graphSz = layout.graphSz;
    final viewStart = layout.viewStart;
    final viewEnd = layout.viewEnd;
    final viewSamples = layout.viewSamples;

    final activeIndices = _settings.activeChannelIndices;
    final oldestSample = _data.oldestSample;
    final totalSamples = _data.totalSamples;

    final yRange = computeYRange(viewStart, viewEnd);

    // Map a value in display units to Y pixel
    double valueToY(double val) {
      return graphSz.height -
          (val - yRange.yMin) * graphSz.height / (yRange.yMax - yRange.yMin);
    }

    // -- Grid and labels --
    final grid = Path();
    drawTimeAxis(
      canvas,
      grid,
      graphSz,
      viewStart: viewStart,
      viewEnd: viewEnd,
      oldestSample: oldestSample,
      sampleRate: _data.sampleRate,
      showLabels: showXLabels,
      drawMinor: drawMinorGrid,
      textColor: colorScheme.onSurface,
    );
    drawValueAxis(
      canvas,
      grid,
      graphSz,
      yRange,
      valueToY,
      labelFor: yTickLabel,
      drawMinor: drawMinorGrid,
      textColor: colorScheme.onSurface,
    );
    final gridPen = Paint()
      ..color = colorScheme.onSurface.withAlpha(50)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.2;
    canvas.drawPath(grid, gridPen);

    drawZeroBaseline(
      canvas,
      graphSz,
      yRange,
      valueToY,
      colorScheme.onSurface.withAlpha(130),
    );

    drawMissingDataHatching(
      canvas,
      graphSz,
      viewStart: viewStart,
      viewEnd: viewEnd,
      data: _data,
      color: colorScheme.error,
    );

    drawOverlay(canvas, graphSz);

    // -- Data lines (tile-cached envelope) --
    final currentConfig = CacheConfig(
      graphSz.width,
      graphSz.height,
      viewSamples,
      yRange.yMin,
      yRange.yMax,
      cacheKeyTares(),
      dpr,
    );

    paintCachedChannels(
      canvas,
      cache,
      currentConfig,
      viewStart: viewStart,
      viewEnd: viewEnd,
      totalSamples: totalSamples,
      oldestSample: oldestSample,
      graphW: graphSz.width,
      drawChunk: (cCanvas, chunkStartSample, chunkEndSample, limitSamples) {
        for (final ch in activeIndices) {
          if (_data.channel(ch).data.isEmpty) continue;

          drawChannelEnvelope(
            cCanvas,
            color: getChannelColor(ch),
            graphW: graphSz.width,
            viewStart: chunkStartSample,
            viewSamples: viewSamples,
            oldestSample: oldestSample,
            totalSamples: limitSamples,
            firstUsableSample: math.max(
              oldestSample + firstSampleOffset,
              chunkStartSample,
            ),
            sampleAt: sampleAt(ch),
            valueToY: (v) => valueToY(v).clamp(0.0, graphSz.height),
            showEnvelope: showEnvelope,
            clipEnvelopeSamples: chunkEndSample,
          );
        }
      },
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Force graph: each channel's tared value in the selected display unit.
class ForceGraphPainter extends _TimeSeriesGraphPainter {
  @override
  final bool showXLabels;

  ForceGraphPainter(
    super.data,
    super.settings,
    super.ctrl, {
    this.showXLabels = true,
    super.showEnvelope,
    required super.cache,
    required super.colorScheme,
    required super.dpr,
  });

  @override
  double get topSpace => 4;

  @override
  bool get drawMinorGrid => true;

  @override
  List<double> cacheKeyTares() => _settings.activeChannelIndices
      .map((ch) => _data.channel(ch).tare)
      .toList();

  @override
  double Function(int j) sampleAt(int channel) {
    final s = _data.channel(channel);
    final line = s.data;
    final tare = s.tare;
    final bufferCap = _data.bufferCapacity;
    final sentinel = _data.missingSampleSentinel;
    final slopeToUnit = _settings.displayUnit.multiplierFromRaw(
      _data.calibrationSlope,
    );
    return (j) {
      final val = line[j % bufferCap];
      if (sentinel != null && val == sentinel) return double.nan;
      return (val - tare) * slopeToUnit;
    };
  }

  @override
  YAxisRange computeYRange(int viewStart, int viewEnd) {
    // Compute data min/max across active channels in visible window (raw,
    // tare-subtracted) so the noise floor stays a raw-count threshold, then
    // convert to display units.
    final oldestSample = _data.oldestSample;
    final totalSamples = _data.totalSamples;
    double rawMax = 0;
    double rawMin = 0;
    bool hasData = false;

    for (final ch in _settings.activeChannelIndices) {
      final s = _data.channel(ch);
      final line = s.data;
      if (line.isEmpty) continue;
      final tare = s.tare;
      final bufferCap = _data.bufferCapacity;
      final sentinel = _data.missingSampleSentinel;
      final sScanStart = math.max(viewStart, oldestSample);
      final sScanEnd = math.min(viewEnd, totalSamples);
      for (int i = sScanStart; i < sScanEnd; i++) {
        final rawVal = line[i % bufferCap];
        if (sentinel != null && rawVal == sentinel) continue;
        final v = rawVal - tare;
        if (!hasData || v > rawMax) rawMax = v.toDouble();
        if (!hasData || v < rawMin) rawMin = v.toDouble();
        hasData = true;
      }
    }

    // Enforce a minimum visible range (noise floor) so the graph isn't degenerate
    const double noiseFloor = 10000; // raw counts
    if (rawMax - rawMin < noiseFloor) {
      final mid = (rawMax + rawMin) / 2;
      rawMax = mid + noiseFloor / 2;
      rawMin = mid - noiseFloor / 2;
    }

    final unit = _settings.displayUnit;
    return _computeYRange(
      unit.fromRaw(rawMin, _data.calibrationSlope),
      unit.fromRaw(rawMax, _data.calibrationSlope),
    );
  }

  @override
  String yTickLabel(double tick) =>
      _formatTickLabel(tick, _settings.displayUnit.symbol);
}

/// Derivative graph: the first difference of each channel, scaled to display
/// units per second.
class DerivativeGraphPainter extends _TimeSeriesGraphPainter {
  DerivativeGraphPainter(
    super.data,
    super.settings,
    super.ctrl, {
    super.showEnvelope,
    required super.cache,
    required super.colorScheme,
    required super.dpr,
  });

  @override
  double get topSpace => 2;

  @override
  int get firstSampleOffset => 1; // first difference needs sample j-1

  @override
  double Function(int j) sampleAt(int channel) {
    final line = _data.channel(channel).data;
    final bufferCap = _data.bufferCapacity;
    final sentinel = _data.missingSampleSentinel;
    final scale =
        _settings.displayUnit.multiplierFromRaw(_data.calibrationSlope) *
        _data.sampleRate;
    return (j) {
      final v1 = line[j % bufferCap];
      final v2 = line[(j - 1) % bufferCap];
      if (sentinel != null && (v1 == sentinel || v2 == sentinel)) {
        return double.nan;
      }
      return (v1 - v2) * scale;
    };
  }

  @override
  YAxisRange computeYRange(int viewStart, int viewEnd) {
    // Compute derivative min/max (in display units) across the visible window.
    double dMin = 0;
    double dMax = 0;
    bool first = true;
    final startI = math.max(viewStart, _data.oldestSample + 1);
    final endI = math.min(viewEnd, _data.totalSamples);
    for (final ch in _settings.activeChannelIndices) {
      if (_data.channel(ch).data.isEmpty) continue;
      final valueAt = sampleAt(ch);
      for (int i = startI; i < endI; i++) {
        final d = valueAt(i);
        if (d.isNaN) continue;
        if (first) {
          dMin = d;
          dMax = d;
          first = false;
        } else {
          if (d < dMin) dMin = d;
          if (d > dMax) dMax = d;
        }
      }
    }
    return _computeYRange(dMin, dMax);
  }

  @override
  String yTickLabel(double tick) => '${_formatTickValue(tick)}/s';

  @override
  void drawOverlay(Canvas canvas, Size graphSz) {
    // "dF/dt" label in top-left
    final dLabel = _prepareLabel(
      'dF/dt (${_settings.displayUnit.symbol}/s)',
      color: colorScheme.onSurface.withAlpha(150),
    );
    canvas.drawParagraph(dLabel, const Offset(4, 2));
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Format a tick value with appropriate precision.
String _formatTickLabel(double value, String unitSymbol) {
  final formatted = _formatTickValue(value);
  return '$formatted $unitSymbol';
}

String _formatTickValue(double value) {
  if (value == 0) return '0';
  final abs = value.abs();
  if (abs >= 100) return value.toStringAsFixed(0);
  if (abs >= 1) return value.toStringAsFixed(1);
  if (abs >= 0.1) return value.toStringAsFixed(2);
  return value.toStringAsFixed(3);
}

/// Return a "nice" number close to [value] for axis step sizes.
double _niceNum(double value) {
  if (value <= 0) return 1;
  final exp = (math.log(value) / math.ln10).floor();
  final frac = value / math.pow(10, exp);
  double nice;
  if (frac < 1.5) {
    nice = 1;
  } else if (frac < 3.5) {
    nice = 2;
  } else if (frac < 7.5) {
    nice = 5;
  } else {
    nice = 10;
  }
  return nice * math.pow(10, exp);
}
