import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meta/meta.dart';

import '../models/analysis_pane.dart';
import '../models/bucket_series.dart';
import '../models/channel_limits.dart';
import '../models/derived_channel.dart';
import '../models/device_profile.dart';
import '../models/display_unit.dart';
import '../models/gap_list.dart';
import '../models/graph_data_source.dart';
import '../models/graph_overlays.dart';
import '../models/load_cell.dart';
import '../utils/fft.dart';
import 'channel_palette.dart';
import 'graph/force_plate_cache.dart';
import 'graph/graph_controller.dart';
import 'graph/segmented_cache.dart';

export 'graph/force_plate_cache.dart';
export 'graph/graph_controller.dart';
export 'graph/segmented_cache.dart';

// ---------------------------------------------------------------------------
// Shared graph layout constants
// ---------------------------------------------------------------------------

/// Horizontal/vertical padding shared by the graph painters and the gesture
/// areas. [kGraphRightSpace] reserves room for the Y-axis labels; public so
/// the controls row in `GraphViewControls` can align its right edge with
/// the painted plot/minimap edge.
const double _kGraphLeftSpace = 8;
const double kGraphRightSpace = 56;
const double _kGraphBottomSpace = 24;

double _graphPlotWidth(double totalWidth) =>
    totalWidth - _kGraphLeftSpace - kGraphRightSpace;

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

  final focalFrac = ((event.localPosition.dx - _kGraphLeftSpace) / graphWidth)
      .clamp(0.0, 1.0);
  final zoomFactor = event.scrollDelta.dy < 0 ? 1.2 : 1 / 1.2;
  ctrl.zoom(zoomFactor, focalFrac, totalSamples, data.oldestSample);
}

// ---------------------------------------------------------------------------
// Shared Graph Data Source
// ---------------------------------------------------------------------------

/// Number of samples reduced into a single envelope/line "block".
///
/// One block becomes one min/avg/max reduction and one polyline vertex. When
/// zoomed in past 1 sample/pixel this clamps to 1 (one block per sample). The
/// last block in a range is allowed to be short.
int _blockSizeFor(double viewSamples, double graphW) {
  assert(
    graphW > 0,
    'graphW must be positive, got $graphW',
  ); // callers only paint into non-degenerate plot areas
  // floor => >= 1 sample/block, so the polyline never has more vertices than
  // pixels. The remainder (viewSamples % blockSize) lands in the short final block.
  return math.max(1, (viewSamples / graphW).floor());
}

/// How far past a segment end its render reduces (in blocks) for the seam
/// join -- and, being the same quantity, how far behind the data edge bakes
/// stay so a baked join block is always complete (see [joinBlockEnd] and
/// the bakeableSamples horizon in [_paintEnvelopeDataLayer]).
const int _kJoinBlockSlackBlocks = 2;

/// The sample index a segment render must reduce through for its seam join
/// to match the neighbor segment: the polyline overshoots the segment end
/// into the first block past it (the "join block"), and that block must be
/// reduced over its FULL natural range so the join vertex equals the
/// neighbor's vertex for the same block. A join block truncated at the
/// segment end lands at a different (partial-data) average, which reads as a
/// vertical step at the seam.
///
/// The result is block-aligned and lies in (end + blockSize, end +
/// _kJoinBlockSlackBlocks * blockSize]; capping at totalSamples is the
/// caller's job (the envelope layer keeps bakes that many block sizes
/// behind the data edge, so a baked join block is always complete -- see
/// [SegmentedGraphCache.paint]).
@visibleForTesting
int joinBlockEnd(int end, int blockSize) =>
    (end ~/ blockSize + _kJoinBlockSlackBlocks) * blockSize;

// ---------------------------------------------------------------------------
// Unit-bound channels
// ---------------------------------------------------------------------------

/// One active channel bound to the view's display unit, spanning the whole
/// channel id space (hardware 0..3, derived 4.. — see `derived_channel.dart`).
/// Its display maps are materialized non-null here, so painters never re-ask
/// availability. What the shared envelope engine needs to know about it:
/// an ink color.
@immutable
final class _ConvertedChannel {
  const _ConvertedChannel._({
    required this.channel,
    required this.cacheTares,
    required this.netMap,
    required this.diffMap,
    required this.fullScaleRaw,
    required this.unitless,
    required this.hardwareIndex,
    required this.sensitivityCountsPerMvV,
    required this.loadCell,
  });

  /// Null when [unit] does not convert on the channel (a force unit with no
  /// load cell assigned, a blend asked for mV/V, an unbound channel).
  static _ConvertedChannel? of(
    GraphDataSource data,
    int channel,
    DisplayUnit unit,
  ) {
    final converter = data.seriesConverterFor(channel);
    final net = converter.netMap(unit);
    if (net == null) return null;
    final diff = converter.diffMap(unit);
    // diff is null exactly when net is (see SeriesConverter); a divergence
    // is a broken conversion-model invariant, not an unavailable unit.
    assert(diff != null, 'net converts but diff does not (CH$channel, $unit)');
    if (diff == null) return null;
    final hw = isDerivedChannelId(channel) ? null : channel;
    return _ConvertedChannel._(
      channel: channel,
      cacheTares: data.cacheTaresFor(channel),
      netMap: net,
      diffMap: diff,
      fullScaleRaw: converter.fullScaleRaw,
      unitless: converter.unitless,
      hardwareIndex: hw,
      sensitivityCountsPerMvV: hw == null
          ? null
          : data.converterFor(hw).calibration.board?.sensitivityCountsPerMvV,
      loadCell: hw == null ? null : data.converterFor(hw).calibration.loadCell,
    );
  }

  /// The channel id: hardware index for hardware channels, the derived id
  /// (kAdcChannelCount + config index) for derived ones.
  final int channel;

  /// Tares of every hardware channel read, mixed into the segment caches'
  /// destructive key (see [GraphDataSource.cacheTaresFor]).
  final List<double?> cacheTares;

  /// Ring -> display value, net of tare ([SeriesConverter.netMap]).
  final double Function(double raw) netMap;

  /// Ring diff -> display diff ([SeriesConverter.diffMap]).
  final double Function(double rawDiff) diffMap;

  /// Full-scale span in ring units — the FFT's dBFS reference.
  final double fullScaleRaw;

  /// Normalized (unitless) channel: display maps ignore the selected unit.
  final bool unitless;

  /// The hardware channel index, or null for a derived channel (derived
  /// channels have no rail/capacity chrome of their own).
  final int? hardwareIndex;

  /// Board sensitivity, used to size the force graph gutter's capacity zone
  /// (hardware channels with board data only).
  final double? sensitivityCountsPerMvV;

  /// Null when no cell is assigned (or the channel is derived).
  final LoadCellProfile? loadCell;

  /// Stroke/fill color.
  Color get color => getChannelColor(channel);
}

// ---------------------------------------------------------------------------
// Minimap
// ---------------------------------------------------------------------------

class _Minimap extends StatefulWidget {
  final GraphDataSource dataSource;
  final DisplayUnit unit;
  final GraphController graphCtrl;

  /// The series to plot — the same ones as the top graph.
  final List<_ConvertedChannel> channels;

  /// While the FFT pane is active, the samples feeding the transform are
  /// highlighted under the viewport rect (with the pane's N request).
  final ({int? requestedN})? fftFeed;

  const _Minimap({
    required this.dataSource,
    required this.unit,
    required this.graphCtrl,
    required this.channels,
    this.fftFeed,
  });

  @override
  State<_Minimap> createState() => _MinimapState();
}

class _MinimapState extends State<_Minimap> {
  final SegmentedGraphCache _cache = SegmentedGraphCache();
  final BakePump _bakePump = BakePump();

  @override
  void dispose() {
    _bakePump.dispose();
    _cache.dispose();
    super.dispose();
  }

  void _onMinimapTap(TapDownDetails d, double graphWidth) {
    final totalSamples = widget.dataSource.totalSamples;
    if (totalSamples == 0 || graphWidth <= 0) return;
    final oldestSample = widget.dataSource.oldestSample;
    final frac = ((d.localPosition.dx - _kGraphLeftSpace) / graphWidth).clamp(
      0.0,
      1.0,
    );
    final mapSpan = widget.graphCtrl.defaultLiveSpan(
      totalSamples,
      oldestSample,
    );
    final mapStart = totalSamples - mapSpan;
    widget.graphCtrl.centerOn(
      mapStart + (frac * mapSpan).round(),
      totalSamples,
      oldestSample,
    );
  }

  void _onMinimapDrag(DragUpdateDetails d, double graphWidth) {
    final totalSamples = widget.dataSource.totalSamples;
    if (totalSamples == 0 || graphWidth <= 0) return;
    final oldestSample = widget.dataSource.oldestSample;
    final samplesPerPixel =
        widget.graphCtrl.defaultLiveSpan(totalSamples, oldestSample) /
        graphWidth;
    widget.graphCtrl.pan(
      (d.delta.dx * samplesPerPixel).round(),
      totalSamples,
      oldestSample,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphWidth = _graphPlotWidth(constraints.maxWidth);
        return SizedBox(
          height: 32,
          // The tap/drag pan affordance is synthesized as semantics actions by
          // the GestureDetector; without a label it is an anonymous control.
          child: Semantics(
            container: true,
            label: 'Graph history overview',
            hint: 'Tap or drag to move the visible window',
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
                    widget.unit,
                    widget.graphCtrl,
                    widget.channels,
                    widget.fftFeed,
                    colorScheme,
                    dpr,
                    _cache,
                    _bakePump,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MinimapPainter extends CustomPainter {
  final GraphDataSource _data;
  final DisplayUnit _unit;
  final GraphController _ctrl;
  final List<_ConvertedChannel> _channels;
  final ({int? requestedN})? _fftFeed;
  final ColorScheme _colorScheme;
  final double _dpr;
  final SegmentedGraphCache _cache;

  /// Drives the rolling segment bakes: a repaint listenable for this painter
  /// and the scheduler for extra frames when bake work remains (rolling
  /// bootstrap / staleness passes must complete even for static sources
  /// whose [GraphDataSource.repaint] never fires).
  final BakePump _bakePump;

  _MinimapPainter(
    this._data,
    this._unit,
    this._ctrl,
    this._channels,
    this._fftFeed,
    this._colorScheme,
    this._dpr,
    this._cache,
    this._bakePump,
  ) : super(repaint: Listenable.merge([_data.repaint, _ctrl, _bakePump]));

  @override
  void paint(Canvas canvas, Size size) {
    const double vPad = 2;

    canvas.translate(_kGraphLeftSpace, vPad);
    final gw = size.width - _kGraphLeftSpace - kGraphRightSpace;
    final gh = size.height - vPad * 2;

    if (gw <= 0 || gh <= 0) return;

    final bgPaint = Paint()..color = _colorScheme.surface;
    canvas.drawRect(Rect.fromLTWH(0, 0, gw, gh), bgPaint);

    final totalSamples = _data.totalSamples;
    if (totalSamples == 0) return;

    final oldestSample = _data.oldestSample;
    final mapSpan = _ctrl.defaultLiveSpan(totalSamples, oldestSample);
    final mapStart = totalSamples - mapSpan;

    final channels = _channels;
    final unit = _unit;

    // Bucket-folded extremes over the drawable window, like the force
    // painter. Whole-ingest [GraphDataSource.channelExtremes] never shrink,
    // so after a ring wrap they would keep scaling Y by evicted samples the
    // minimap can no longer draw. Zero is a display-space anchor, included
    // even when the data does not cross it.
    double yMin = double.infinity;
    double yMax = double.negativeInfinity;
    for (final s in channels) {
      final ext = _data.windowedRawExtremes(s.channel, mapStart, totalSamples);
      if (ext == null) continue;
      yMin = math.min(yMin, math.min(s.netMap(ext.$1), 0.0));
      yMax = math.max(yMax, math.max(s.netMap(ext.$2), 0.0));
    }
    if (!yMin.isFinite || !yMax.isFinite) return;
    // Non-degenerate on flat data (the mapping divides by the span).
    if (yMax <= yMin) yMax = yMin + 1;

    // Hatching sits behind the data lines, like the main graphs.
    _drawMissingDataHatching(
      canvas,
      Size(gw, gh),
      viewStart: mapStart.toDouble(),
      viewEnd: (mapStart + mapSpan).toDouble(),
      data: _data,
      color: _colorScheme.error,
    );

    // Shared envelope data layer (see [_paintEnvelopeDataLayer]).
    final workRemains = _paintEnvelopeDataLayer(
      canvas,
      cache: _cache,
      data: _data,
      channels: channels,
      tares: [for (final s in channels) ...s.cacheTares],
      unit: unit,
      gw: gw,
      gh: gh,
      dpr: _dpr,
      viewStart: mapStart.toDouble(),
      viewSpan: mapSpan.toDouble(),
      yMin: yMin,
      yMax: yMax,
      firstUsableSample: oldestSample,
      seriesFor: (s) => _taredEnvelopeSeries(_data, s),
      avgStrokeWidth: 1.0,
      avgAlpha: 180,
    );
    if (workRemains) _bakePump.schedule();

    final (viewStart, viewEnd) = _ctrl.effectiveRange(
      totalSamples,
      oldestSample,
    );

    // FFT pane active: highlight the exact samples feeding the transform
    // (the last N of the viewport), so its window rule is visible UI.
    final feed = _fftFeed;
    if (feed != null) {
      final usable =
          viewEnd - (viewStart > oldestSample ? viewStart : oldestSample);
      final n = fftWindowN(usable, feed.requestedN);
      if (n != null) {
        final feedStart = math.max(viewEnd - n, oldestSample).toDouble();
        canvas.drawRect(
          Rect.fromLTRB(
            (feedStart - mapStart) * gw / mapSpan,
            0,
            (viewEnd - mapStart) * gw / mapSpan,
            gh,
          ),
          Paint()..color = _colorScheme.primary.withAlpha(32),
        );
      }
    }

    // A parked window stays pinned in absolute time as eviction passes it
    // (see [GraphController.effectiveRange]), so the box slides off the
    // left; clamp it to the map or its border would draw into the Y-label
    // gutter. Fully off it collapses to a line on the left edge -- the
    // main graph shows the "beyond history" state.
    final double x1 = ((viewStart - mapStart) * gw / mapSpan).clamp(0.0, gw);
    final double x2 = ((viewEnd - mapStart) * gw / mapSpan).clamp(0.0, gw);

    final dimPaint = Paint()..color = _colorScheme.onSurface.withAlpha(60);
    if (x1 > 0) canvas.drawRect(Rect.fromLTWH(0, 0, x1, gh), dimPaint);
    if (x2 < gw) canvas.drawRect(Rect.fromLTWH(x2, 0, gw - x2, gh), dimPaint);

    final vpBorder = Paint()
      ..color = _colorScheme.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(Rect.fromLTRB(x1, 0, x2, gh), vpBorder);
  }

  // Repaints are driven by the repaint listenable; the painter is rebuilt only
  // on a widget rebuild, so an unconditional true is cheaper than a field diff.
  @override
  bool shouldRepaint(covariant _MinimapPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Interactive Graph Area (handles gestures)
// ---------------------------------------------------------------------------

class _InteractiveGraphArea extends StatefulWidget {
  final GraphDataSource data;
  final GraphController ctrl;
  final Widget child;

  const _InteractiveGraphArea({
    required this.data,
    required this.ctrl,
    required this.child,
  });

  @override
  State<_InteractiveGraphArea> createState() => _InteractiveGraphAreaState();
}

class _InteractiveGraphAreaState extends State<_InteractiveGraphArea> {
  /// The in-flight pan/pinch gesture's captured-at-start state, or null. One
  /// record, so partial gesture states are unrepresentable.
  ({double focalX, int startSample, int span, bool wasLive})? _session;

  void _onScaleStart(ScaleStartDetails details) {
    final total = widget.data.totalSamples;
    if (total == 0) return;

    final (s, e) = widget.ctrl.effectiveRange(total, widget.data.oldestSample);
    _session = (
      focalX: details.localFocalPoint.dx,
      startSample: s,
      span: e - s,
      wasLive: widget.ctrl.isLive,
    );
  }

  void _onScaleUpdate(ScaleUpdateDetails details, double graphWidth) {
    final total = widget.data.totalSamples;
    final session = _session;
    if (total == 0 || session == null || graphWidth <= 0) return;

    final oldestSample = widget.data.oldestSample;

    if (details.scale != 1.0) {
      // Anchored to the gesture-start window so tracking stays stable while
      // totalSamples grows. The focal fraction is measured from the plot's
      // left edge, like wheel zoom.
      widget.ctrl.zoomTo(
        (session.span / details.scale).round(),
        ((session.focalX - _kGraphLeftSpace) / graphWidth).clamp(0.0, 1.0),
        baseStart: session.startSample,
        baseSpan: session.span,
        anchorLiveEdge: session.wasLive,
        totalSamples: total,
        oldestSample: oldestSample,
      );
    } else {
      final dx = details.localFocalPoint.dx - session.focalX;
      final deltaSamples = -(dx * session.span / graphWidth).round();
      widget.ctrl.applyWindow(
        session.startSample + deltaSamples,
        session.span,
        total,
        oldestSample,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphWidth = _graphPlotWidth(constraints.maxWidth);
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

  /// Resolved against the data source's availability
  /// (see [DisplayUnit.effective]).
  final DisplayUnit unit;

  /// Indices of the channels to plot.
  final List<int> activeChannels;

  /// Which derived view (if any) occupies the analysis pane slot between the
  /// force graph and the minimap, plus that pane's parameters.
  final AnalysisPaneSelection analysis;

  /// Whether the source is the live feed (vs a loaded session); gates the
  /// LIVE button and the semantics wording. Unrelated to
  /// [GraphController.isLive] (viewport mode) and
  /// [GraphController.lockedLiveSpan] (rolling animation).
  final bool isLiveSource;

  /// Annotation chrome drawn behind the force/coords graphs' traces
  /// (guided-test rep phases).
  final GraphOverlays? overlays;

  const GraphWorkspace({
    super.key,
    required this.data,
    required this.ctrl,
    required this.unit,
    required this.activeChannels,
    this.analysis = const AnalysisPaneSelection(),
    this.isLiveSource = true,
    this.overlays,
  });

  @override
  State<GraphWorkspace> createState() => _GraphWorkspaceState();
}

class _GraphWorkspaceState extends State<GraphWorkspace>
    with SingleTickerProviderStateMixin {
  final SegmentedGraphCache _forceCache = SegmentedGraphCache();

  /// Cache for the coordinates graph (the unitless channels' split pane —
  /// see [build]); like [_forceCache], it serves one painter kind only.
  final SegmentedGraphCache _coordCache = SegmentedGraphCache();

  /// Cache for the analysis pane's time-series variants (the derivative);
  /// recreated when the pane KIND changes so a previous pane's segments
  /// can't ghost into the new one.
  SegmentedGraphCache? _analysisCache;

  /// Dot textures for the 2D force plate pane. Persistent (no recreation on
  /// pane swaps): [ForcePlateCache] clears itself on its config stamp.
  final ForcePlateCache<_PlateMarker> _plateDotCache = ForcePlateCache();

  /// Memoized spectra for the FFT pane (throttles recompute, see [_FftCache]).
  final _FftCache _fftCache = _FftCache();

  final BakePump _bakePump = BakePump();
  final _LabelCache _labelCache = _LabelCache();

  /// Vsync driver for smooth live-edge scrolling; the painters merge [_vsync]
  /// into their repaint listenable.
  late final Ticker _ticker;
  final ValueNotifier<int> _vsync = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      _vsync.value++;
      _syncTicker(); // a stalled stream stops the ticker from within
    });
    widget.ctrl.addListener(_syncTicker);
    widget.data.repaint.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void didUpdateWidget(GraphWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ctrl != widget.ctrl || oldWidget.data != widget.data) {
      oldWidget.ctrl.removeListener(_syncTicker);
      oldWidget.data.repaint.removeListener(_syncTicker);
      widget.ctrl.addListener(_syncTicker);
      widget.data.repaint.addListener(_syncTicker);
      _syncTicker();
    }
    if (oldWidget.data != widget.data) {
      // A swapped data source may alias the cache key (static sources share
      // dataGeneration 0); drop the memo.
      _fftCache.clear();
    }
    if (oldWidget.analysis.kind != widget.analysis.kind) {
      _analysisCache?.dispose();
      _analysisCache = null;
    }
  }

  /// Runs only while a rolling live window animates on a fresh stream; the
  /// next packet's repaint restarts it after a stall. Data-pinned views
  /// (parked, or live "everything") don't tick: nothing on screen moves
  /// between packets there, so the packet's own repaint suffices.
  void _syncTicker() {
    final DateTime? last = widget.data.lastDataAt;
    final bool fresh =
        last != null &&
        DateTime.now().difference(last).inMilliseconds < _kTickerStallMs;
    final bool shouldTick = widget.ctrl.lockedLiveSpan != null && fresh;
    // isActive, not isTicking: start() throws on isActive, and a started
    // ticker is active before its first frame, so isTicking can't guard a
    // double start() (web delivers batches as in-frame microtasks).
    if (shouldTick == _ticker.isActive) return;
    shouldTick ? _ticker.start() : _ticker.stop();
  }

  @override
  void dispose() {
    widget.ctrl.removeListener(_syncTicker);
    widget.data.repaint.removeListener(_syncTicker);
    _ticker.dispose();
    _vsync.dispose();
    _bakePump.dispose();
    _forceCache.dispose();
    _coordCache.dispose();
    _analysisCache?.dispose();
    _plateDotCache.dispose();
    _labelCache.dispose();
    super.dispose();
  }

  /// The analysis pane slot's content: a pane widget for the current
  /// selection, or null when collapsed. Panes whose channels can't bind in
  /// [unit] fail loudly with the reason (see [_bindWhy]) rather than
  /// plotting nothing. [bound] is the workspace's active-channel list,
  /// unit-bound — the channel selection [AnalysisPaneKind.derivative] and
  /// [AnalysisPaneKind.fft] plot.
  Widget? _buildAnalysisPane(
    BuildContext context,
    ColorScheme colorScheme,
    double dpr,
    DisplayUnit unit,
    List<_ConvertedChannel> bound,
  ) {
    final sel = widget.analysis;
    final data = widget.data;
    final ctrl = widget.ctrl;

    Widget unavailable(String pane, int id) =>
        _paneMessage(context, '$pane: ${_bindWhy(data, id, unit)}');

    switch (sel.kind) {
      case null:
        return null;
      case AnalysisPaneKind.derivative:
        return _GraphPane(
          data: data,
          ctrl: ctrl,
          painter: _DerivativeGraphPainter(
            data,
            ctrl,
            unit: unit,
            channels: bound,
            vsync: _vsync,
            cache: _analysisCache ??= SegmentedGraphCache(),
            colorScheme: colorScheme,
            dpr: dpr,
            labels: _labelCache,
            bakePump: _bakePump,
          ),
        );
      case AnalysisPaneKind.plate:
        final profile = data.mathProfile;
        final xId = profile.plateXId;
        final yId = profile.plateYId;
        final errId = profile.plateErrId;
        if (xId == null || yId == null || errId == null) {
          return _paneMessage(context, 'Plate: no plate profile configured');
        }
        final x = _ConvertedChannel.of(data, xId, unit);
        final y = _ConvertedChannel.of(data, yId, unit);
        final err = _ConvertedChannel.of(data, errId, unit);
        if (x == null) return unavailable('Plate', xId);
        if (y == null) return unavailable('Plate', yId);
        if (err == null) return unavailable('Plate', errId);
        // Corner labels, recovered from the axis channels' weight signs:
        // +x members sit right, +y members on top.
        final corners = _plateCorners(data, xId, yId);
        return _GraphPane(
          data: data,
          ctrl: ctrl,
          painter: _ForcePlatePainter(
            data,
            ctrl,
            xChannel: x,
            yChannel: y,
            errChannel: err,
            corners: corners,
            unit: unit,
            cache: _plateDotCache,
            colorScheme: colorScheme,
            dpr: dpr,
            labels: _labelCache,
            bakePump: _bakePump,
            ellipses: widget.overlays?.plateEllipses ?? const [],
            trails: widget.overlays?.plateTrails ?? const [],
          ),
        );
      case AnalysisPaneKind.fft:
        // The pane plots the bound selection (unbound members drop out,
        // like on the force graph); when EVERY selected channel fails,
        // say why instead of showing a bare "no channels".
        if (bound.isEmpty && widget.activeChannels.isNotEmpty) {
          return unavailable('FFT', widget.activeChannels.first);
        }
        return _GraphPane(
          data: data,
          ctrl: ctrl,
          painter: _FftPanePainter(
            _fftCache,
            data: data,
            ctrl: ctrl,
            channels: bound,
            requestedN: sel.fftN,
            asd: sel.fftAsd,
            logX: sel.fftLogX,
            colorScheme: colorScheme,
            labels: _labelCache,
            unit: unit,
          ),
        );
    }
  }

  /// Why channel [id] can't bind [unit]: member-calibration gaps for a
  /// derived channel ("no load cell on CH 2" — the common dead-plate-pane
  /// cause), the unconfigured-slot case, a force-space blend in an
  /// electrical unit (see [GraphSeriesQueries.isForceOnlyBlend]), else the
  /// generic unit line (a hardware channel without the unit's conversion).
  static String _bindWhy(GraphDataSource data, int id, DisplayUnit unit) {
    if (!isDerivedChannelId(id)) return 'channel unavailable in ${unit.label}';
    final specs = data.derivedChannels;
    final idx = derivedIndexOf(id);
    if (idx >= specs.length) return 'no math channel configured in this slot';
    if (data.isForceOnlyBlend(id, unit)) {
      return 'force-only channel — select a force unit';
    }
    final spec = specs[idx];
    final noCell = [
      for (final m in spec.members)
        if (data.calibrationFor(m).loadCell == null) rigSlotTitle(m),
    ];
    final noBoard = [
      for (final m in spec.members)
        if (data.calibrationFor(m).board == null) rigSlotTitle(m),
    ];
    if (noCell.isEmpty && noBoard.isEmpty) {
      assert(
        false,
        'unbound channel $id (${spec.label}) has every member calibrated',
      );
      return 'channel unavailable in ${unit.label}';
    }
    return [
      if (noCell.isNotEmpty) 'no load cell on ${noCell.join(', ')}',
      if (noBoard.isNotEmpty) 'no board data on ${noBoard.join(', ')}',
    ].join(', ');
  }

  /// Plate-corner membership of two axis channel ids, from their specs'
  /// weight signs (see `_buildAnalysisPane`); empty when either id isn't a
  /// derived channel.
  static List<(int channel, double sx, double sy)> _plateCorners(
    GraphDataSource data,
    int xId,
    int yId,
  ) {
    if (!isDerivedChannelId(xId) || !isDerivedChannelId(yId)) return const [];
    final xs = data.derivedChannels[derivedIndexOf(xId)].weights;
    final ys = data.derivedChannels[derivedIndexOf(yId)].weights;
    return [
      for (int m = 0; m < kAdcChannelCount; m++)
        if (xs[m] != 0 && ys[m] != 0) (m, xs[m].sign, ys[m].sign),
    ];
  }

  /// Loud in-pane placeholder for unsatisfiable analysis requests.
  Widget _paneMessage(BuildContext context, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final unit = widget.unit;
    final convertedChannels = [
      for (final ch in widget.activeChannels)
        ?_ConvertedChannel.of(widget.data, ch, unit),
    ];

    // Family split: unitless plate coordinates never share an axis with
    // forces — a ±1 blend under a kgf autorange reads as a flat zero line
    // with the wrong unit on the axis. Two stacked graphs, one selection.
    final forceChannels = [
      for (final c in convertedChannels)
        if (!c.unitless) c,
    ];
    final coordChannels = [
      for (final c in convertedChannels)
        if (c.unitless) c,
    ];
    final hasForce = forceChannels.isNotEmpty;
    final hasCoords = coordChannels.isNotEmpty;
    final hasPane = widget.analysis.kind != null;

    // Vertical split of the graph region (flexes sum to 10); the analysis
    // pane and the coordinates graph each take a share when present.
    final forceFlex = !hasCoords ? (hasPane ? 6 : 10) : (hasPane ? 4 : 6);
    final coordFlex = !hasForce ? (hasPane ? 6 : 10) : (hasPane ? 3 : 4);
    final paneFlex = hasCoords ? 3 : 4;
    // Time labels ride the bottom-most plot whose x is time. The dF/dt
    // pane draws its own, so the graphs suppress theirs while it's up;
    // the FFT/plate panes have no time axis and leave the labels on the
    // bottom-most time-series graph.
    final paneCarriesTime = widget.analysis.kind == AnalysisPaneKind.derivative;
    final forceXLabels = !hasCoords && !paneCarriesTime;

    Widget timeGraph({
      required List<_ConvertedChannel> channels,
      required SegmentedGraphCache cache,
      required bool showXLabels,
    }) => _GraphPane(
      data: widget.data,
      ctrl: widget.ctrl,
      overlays: widget.overlays,
      painter: _ForceGraphPainter(
        widget.data,
        widget.ctrl,
        unit: unit,
        channels: channels,
        showXLabels: showXLabels,
        vsync: _vsync,
        cache: cache,
        colorScheme: colorScheme,
        dpr: dpr,
        labels: _labelCache,
        bakePump: _bakePump,
      ),
    );

    // The canvas exposes no semantics of its own; explicitChildNodes keeps
    // the overlay button as its own node rather than merging into this label.
    // No LayoutBuilder here (unlike _GraphPane/_Minimap): nothing reads the
    // constraints, and a LayoutBuilder's isolated build scope escalates any
    // descendant setState into an unconditional markNeedsLayout walk to the
    // nearest relayout boundary (the Scaffold on the live tab) plus a
    // layout-phase rebuild of the dirtied elements (runLayoutCallback flushes
    // its build scope) -- even when the rebuild changes nothing render-side;
    // ancestor rebuilds do the same and rebuild the entire subtree during
    // layout (updateShouldRebuild is always true).
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: _graphSemanticsLabel(
        live: widget.isLiveSource,
        channels: [
          for (final bound in convertedChannels)
            isDerivedChannelId(bound.channel) &&
                    derivedIndexOf(bound.channel) <
                        widget.data.derivedChannels.length
                ? widget
                      .data
                      .derivedChannels[derivedIndexOf(bound.channel)]
                      .label
                : rigSlotTitle(bound.channel),
        ],
        unit: unit,
        paneSuffix: switch (widget.analysis.kind) {
          null => '',
          AnalysisPaneKind.derivative => '. Rate-of-change graph below',
          AnalysisPaneKind.fft => '. Spectrum graph below',
          AnalysisPaneKind.plate => '. Two-axis position view below',
        },
      ),
      child: Stack(
        children: [
          Column(
            children: [
              // No bound channels at all: keep the blank-canvas plot area
              // (a pane with no series paints nothing) rather than an empty
              // slot.
              if (!hasForce && !hasCoords)
                Expanded(
                  flex: hasPane ? 6 : 10,
                  child: timeGraph(
                    channels: const [],
                    cache: _forceCache,
                    showXLabels: !paneCarriesTime,
                  ),
                ),
              if (hasForce)
                Expanded(
                  flex: forceFlex,
                  child: timeGraph(
                    channels: forceChannels,
                    cache: _forceCache,
                    showXLabels: forceXLabels,
                  ),
                ),
              if (hasCoords)
                Expanded(
                  flex: coordFlex,
                  child: timeGraph(
                    channels: coordChannels,
                    cache: _coordCache,
                    showXLabels: !paneCarriesTime,
                  ),
                ),
              if (_buildAnalysisPane(
                    context,
                    colorScheme,
                    dpr,
                    unit,
                    convertedChannels,
                  )
                  case final pane?)
                Expanded(flex: paneFlex, child: pane),
              _Minimap(
                dataSource: widget.data,
                unit: unit,
                graphCtrl: widget.ctrl,
                channels: convertedChannels,
                fftFeed: widget.analysis.kind == AnalysisPaneKind.fft
                    ? (requestedN: widget.analysis.fftN)
                    : null,
              ),
            ],
          ),
          if (widget.isLiveSource)
            _LiveButton(data: widget.data, ctrl: widget.ctrl),
        ],
      ),
    );
  }
}

/// One interactive plot surface (gestures + the painted graph), shared by the
/// force and derivative panes.
class _GraphPane extends StatelessWidget {
  const _GraphPane({
    required this.data,
    required this.ctrl,
    required this.painter,
    this.overlays,
  });

  final GraphDataSource data;
  final GraphController ctrl;
  final CustomPainter painter;

  /// Annotation chrome (rep phases), painted behind the trace. Expected only
  /// on time-series panes; pane employments with another x axis (FFT, plate
  /// scatter) would misread them.
  final GraphOverlays? overlays;

  @override
  Widget build(BuildContext context) {
    return _InteractiveGraphArea(
      data: data,
      ctrl: ctrl,
      child: CustomPaint(
        painter: overlays == null
            ? null
            : _OverlayPainter(data, ctrl, overlays!),
        foregroundPainter: painter,
        size: Size.infinite,
      ),
    );
  }
}

/// Paints [GraphOverlays] spans and markers behind a time-series trace. A
/// separate background painter so the giant trace painters stay untouched;
/// horizontal mapping mirrors [_setupGraphFrame].
class _OverlayPainter extends CustomPainter {
  _OverlayPainter(this._data, this._ctrl, this._overlays)
    : super(repaint: Listenable.merge([_data.repaint, _ctrl]));

  final GraphDataSource _data;
  final GraphController _ctrl;
  final GraphOverlays _overlays;

  @override
  void paint(Canvas canvas, Size size) {
    final total = _data.totalSamples;
    if (total < 1) return;
    final (vs, ve) = _ctrl.effectiveRange(total, _data.oldestSample);
    double viewStart = vs.toDouble();
    double viewEnd = ve.toDouble();
    if (_ctrl.isLive) {
      viewEnd = _liveEdge(_data, ve - vs);
      viewStart = viewEnd - (ve - vs);
    }
    final span = viewEnd - viewStart;
    if (span <= 0) return;
    final width = size.width - _kGraphLeftSpace - kGraphRightSpace;
    if (width <= 0) return;
    canvas.translate(_kGraphLeftSpace, 0);
    double xFor(num index) => (index - viewStart) / span * width;

    for (final s in _overlays.spans) {
      final x0 = xFor(s.start).clamp(0.0, width);
      final x1 = xFor(s.end).clamp(0.0, width);
      if (x1 <= x0) continue;
      canvas.drawRect(
        Rect.fromLTRB(x0, 0, x1, size.height),
        Paint()..color = s.color,
      );
    }
    for (final m in _overlays.markers) {
      final x = xFor(m.index);
      if (x < 0 || x > width) continue;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = m.color
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) => true;
}

/// Return to the live edge of a live graph.
class _LiveButton extends StatelessWidget {
  const _LiveButton({required this.data, required this.ctrl});

  final GraphDataSource data;
  final GraphController ctrl;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        if (ctrl.isLive || data.totalSamples == 0) {
          return const SizedBox.shrink();
        }
        return Positioned(
          right: 64,
          top: 8,
          child: FilledButton.icon(
            onPressed: () => ctrl.goLive(
              totalSamples: data.totalSamples,
              oldestSample: data.oldestSample,
            ),
            icon: const Icon(Icons.fast_forward, size: 16),
            label: const Text('LIVE'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        );
      },
    );
  }
}

/// Zoom controls: a split button group [− | span | +]. The middle segment
/// opens a menu of preset window spans, "All" (the whole retained buffer,
/// auto-expanding on live), and a "Custom…" exact-span dialog. A preset is
/// shown only when the source could EVER hold it (the live ring never spans
/// an hour, a 30 s recording never shows minute presets) and greyed until
/// the current data does — so the menu's shape is constant per mount and
/// rows never move, they only un-grey in place as a live stream grows.
/// Row chrome below the graph (see `GraphViewControls`)
class GraphZoomControls extends StatelessWidget {
  const GraphZoomControls({super.key, required this.data, required this.ctrl});

  final GraphDataSource data;
  final GraphController ctrl;

  /// Preset window spans for the middle segment's menu: (seconds, label),
  /// decade steps. "All" and "Custom…" follow in the menu.
  static const _presets = [
    (1, '1 s'),
    (10, '10 s'),
    (60, '1 min'),
    (600, '10 min'),
    (3600, '1 h'),
  ];

  // Split-group shapes, twin of the TARE group in `ActionButtons`: rounded
  // outer corners, small inner corners, segments separated by a 4px gap.
  static const _splitLeft = RoundedRectangleBorder(
    borderRadius: BorderRadius.horizontal(
      left: Radius.circular(20),
      right: Radius.circular(4),
    ),
  );
  static const _splitMid = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(4)),
  );
  static const _splitRight = RoundedRectangleBorder(
    borderRadius: BorderRadius.horizontal(
      left: Radius.circular(4),
      right: Radius.circular(20),
    ),
  );

  /// Zoom by [factor] (>1 in, <1 out), anchored at the live edge when
  /// following it and at the window center otherwise.
  void _zoomBy(double factor) {
    if (data.totalSamples <= 0) return;
    ctrl.zoom(
      factor,
      ctrl.isLive ? 1.0 : 0.5,
      data.totalSamples,
      data.oldestSample,
    );
  }

  /// Set an exact window span in samples. [GraphController.zoomTo] clamps;
  /// passing `defaultLiveSpan` ("All") funnels through `goLive` into the
  /// auto-expanding show-everything view over mature data. Anchoring matches
  /// [_zoomBy].
  void _applySpan(int spanSamples) {
    if (data.totalSamples <= 0) return;
    final (s, e) = ctrl.effectiveRange(data.totalSamples, data.oldestSample);
    ctrl.zoomTo(
      spanSamples,
      ctrl.isLive ? 1.0 : 0.5,
      baseStart: s,
      baseSpan: e - s,
      anchorLiveEdge: ctrl.isLive,
      totalSamples: data.totalSamples,
      oldestSample: data.oldestSample,
    );
  }

  /// Open the exact-span dialog prefilled with the current window. A typed
  /// span beyond the retained data clamps inside [GraphController.zoomTo].
  Future<void> _promptCustomSpan(BuildContext context) async {
    if (data.totalSamples <= 0) return;
    final (start, end) = ctrl.effectiveRange(
      data.totalSamples,
      data.oldestSample,
    );
    final seconds = await showDialog<double>(
      context: context,
      builder: (_) =>
          _CustomSpanDialog(initialSec: (end - start) / data.sampleRate),
    );
    if (seconds == null) return;
    _applySpan((seconds * data.sampleRate).round());
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Zoom out',
          child: FilledButton(
            style: FilledButton.styleFrom(
              shape: _splitLeft,
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            onPressed: () => _zoomBy(1 / 1.1892), // fourth root of 2
            child: const Icon(Icons.zoom_out),
          ),
        ),
        const SizedBox(width: 4),
        // Listens so a growing live stream re-derives each preset's greyed
        // state; the show/hide ceiling itself is static per source.
        ListenableBuilder(
          listenable: data.repaint,
          builder: (context, _) {
            final available = data.totalSamples - data.oldestSample;
            return MenuAnchor(
              builder: (context, menu, _) => Tooltip(
                message: 'Visible time window',
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    shape: _splitMid,
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                  child: _SpanReadout(data: data, ctrl: ctrl),
                ),
              ),
              menuChildren: [
                for (final (sec, label) in _presets)
                  if (sec * data.sampleRate <= data.maxViewableSamples)
                    MenuItemButton(
                      onPressed: sec * data.sampleRate > available
                          ? null
                          : () => _applySpan(sec * data.sampleRate),
                      child: Text(label),
                    ),
                MenuItemButton(
                  onPressed: () => _applySpan(
                    ctrl.defaultLiveSpan(data.totalSamples, data.oldestSample),
                  ),
                  child: const Text('All'),
                ),
                MenuItemButton(
                  onPressed: () => _promptCustomSpan(context),
                  child: const Text('Custom…'),
                ),
              ],
            );
          },
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: 'Zoom in',
          child: FilledButton(
            style: FilledButton.styleFrom(
              shape: _splitRight,
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            onPressed: () => _zoomBy(1.1892),
            child: const Icon(Icons.zoom_in),
          ),
        ),
      ],
    );
  }
}

/// Exact-span entry: a digits-and-dot-only number field plus a unit
/// selector. [FilteringTextInputFormatter] (not [TextInputType], which is a
/// keyboard-layout hint that filters nothing) makes non-numeric input
/// untypeable on every input path, and Apply is enabled only for a
/// numerically valid positive value — so the dialog has no error states at
/// all: garbage is either untypeable or leaves the button greyed.
class _CustomSpanDialog extends StatefulWidget {
  const _CustomSpanDialog({required this.initialSec});

  /// Current window span in seconds; prefill (whole-value selected).
  final double initialSec;

  @override
  State<_CustomSpanDialog> createState() => _CustomSpanDialogState();
}

class _CustomSpanDialogState extends State<_CustomSpanDialog> {
  /// Unit-selector multipliers to seconds; the typed number is
  /// reinterpreted in the selected unit, not converted between units.
  static const _unitFactors = {'ms': 0.001, 's': 1.0, 'min': 60.0, 'h': 3600.0};

  late final TextEditingController _text;
  String _unit = 's';

  /// The entered span in seconds; null = not a positive number (empty,
  /// zero, or formatter-passable garbage like "1.2.3").
  double? get _seconds {
    final value = double.tryParse(_text.text);
    return value == null || value <= 0 ? null : value * _unitFactors[_unit]!;
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSec;
    final text = initial % 1 == 0
        ? initial.toStringAsFixed(0)
        : initial.toStringAsFixed(1);
    _text = TextEditingController(text: text)
      // Apply's enabled state depends on the text.
      ..addListener(() => setState(() {}));
    _text.selection = TextSelection(baseOffset: 0, extentOffset: text.length);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _apply() {
    final seconds = _seconds;
    if (seconds != null) Navigator.of(context).pop(seconds);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Window span'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Span',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _apply(),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'ms', label: Text('ms')),
              ButtonSegment(value: 's', label: Text('s')),
              ButtonSegment(value: 'min', label: Text('min')),
              ButtonSegment(value: 'h', label: Text('h')),
            ],
            selected: {_unit},
            onSelectionChanged: (unit) => setState(() => _unit = unit.first),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _seconds == null ? null : _apply,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// The current zoom-window span (e.g. "800 ms", "12.4 s", "1:02:05").
class _SpanReadout extends StatelessWidget {
  const _SpanReadout({required this.data, required this.ctrl});

  final GraphDataSource data;
  final GraphController ctrl;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ctrl, data.repaint]),
      builder: (context, _) {
        final (start, end) = ctrl.effectiveRange(
          data.totalSamples,
          data.oldestSample,
        );
        return Container(
          // Wide enough for hours-folded spans ("1:00:00") in bold tabular
          // figures; replay windows can legitimately exceed an hour.
          width: 68,
          alignment: Alignment.center,
          child: Text(
            formatWindowSpan((end - start) / data.sampleRate),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onPrimary,
              fontWeight: FontWeight.bold,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        );
      },
    );
  }
}

/// Screen-reader summary of the graph: structural only, since values churn
/// per packet. The stats table speaks live readings. [paneSuffix] names the
/// analysis pane below the force graph ('. Rate-of-change graph below'), or
/// is empty when the slot is collapsed.
String _graphSemanticsLabel({
  required bool live,
  required List<String> channels,
  required DisplayUnit unit,
  required String paneSuffix,
}) {
  final kind = live ? 'Live' : 'Recorded';
  final chs = channels.isEmpty
      ? 'No channels plotted'
      : 'Channels: ${channels.join(', ')}';
  return '$kind force graph. $chs. Unit: ${unit.symbol}$paneSuffix.';
}

/// Format a zoom-window span in seconds for the readout: "800 ms" below a
/// second, trimmed decimals below a minute ("12.4 s", "30 s"), then the
/// same hours-folding clock shape as the X axis ticks (see [_fmtTick]):
/// "2:05", "1:00:30".
@visibleForTesting
String formatWindowSpan(double spanSec) {
  if (spanSec < 1.0) return '${(spanSec * 1000).round()} ms';
  if (spanSec < 60.0) {
    final oneDecimal = spanSec.toStringAsFixed(1);
    return '${oneDecimal.endsWith('.0') ? oneDecimal.substring(0, oneDecimal.length - 2) : oneDecimal} s';
  }
  final total = spanSec.floor();
  final m = total ~/ 60;
  final s = (total % 60).toString().padLeft(2, '0');
  if (m < 60) return '$m:$s';
  return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:$s';
}

/// Smallest 1/2/5-decade step >= [target]. Used directly by the Y axis, and
/// by [_timeStepCeil] below one second.
double _decadeStepCeil(double target) {
  final base = math.pow(10, (math.log(target) / math.ln10).floor()).toDouble();
  if (base >= target) return base;
  if (2 * base >= target) return 2 * base;
  if (5 * base >= target) return 5 * base;
  return 10 * base;
}

/// Clock-nice step ladder, as rungs of seconds/minutes/hours, used by
/// [_timeStepCeil]. 30 s and friends keep m:ss labels meaningful; a 1/2/5
/// decade of "100 s" would print 1:40.
const _kClockRungs = [1, 2, 5, 10, 20, 30, 60];

/// Smallest clock-nice step >= [target] seconds: 1/2/5 decades below one
/// second, then [_kClockRungs] of seconds, minutes, hours, ...
double _timeStepCeil(double target) {
  if (target < 1) return _decadeStepCeil(target);
  for (double scale = 1; ; scale *= 60) {
    // Terminates once scale >= target, via r = 1.
    for (final r in _kClockRungs) {
      final step = scale * r;
      if (step >= target) return step;
    }
  }
}

/// Format an X-axis tick time (absolute seconds since session start) with
/// [decimals] fractional digits: "42", "0.35", "12:05", "1:00.5". Hours fold
/// per tick: at and past one hour the format grows a field ("1:02:30")
/// instead of minutes running past 59, so the rollover is visible in the
/// axis and a tick's label never depends on the window around it.
String _fmtTick(double sec, int decimals) {
  if (sec < 0) return '-${_fmtTick(-sec, decimals)}';
  // Snap fp noise (ticks are k * step products) so 59.999... prints as 1:00.
  final f = math.pow(10, decimals);
  final snapped = (sec * f).round() / f;
  final int m = snapped ~/ 60;
  final s = (snapped - m * 60).toStringAsFixed(decimals);
  if (m == 0) return s;
  final ss = s.padLeft(decimals == 0 ? 2 : decimals + 3, '0');
  if (m < 60) return '$m:$ss';
  return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:$ss';
}

// ---------------------------------------------------------------------------
// Axis label paragraph cache
// ---------------------------------------------------------------------------

/// Bounded cache of laid-out axis-label paragraphs. Owned by a host [State]:
/// painters are recreated on rebuild, so a painter-owned cache would drop
/// constantly. Clears on overflow and rebuilds the visible labels next paint.
class _LabelCache {
  static const int _limit = 512;

  final Map<String, ui.Paragraph> _cache = HashMap();

  /// The laid-out paragraph for [text] in [color], building and caching it on
  /// first use. [maxWidth] is the layout constraint (default sized for axis
  /// labels; pass the plot width for centered messages).
  ui.Paragraph prepare(
    String text, {
    Color color = Colors.black,
    bool bold = false,
    double maxWidth = 96,
  }) {
    final key = '$text|${color.toARGB32()}|$bold|$maxWidth';
    if (!_cache.containsKey(key) && _cache.length >= _limit) {
      _clear();
    }
    return _cache.putIfAbsent(key, () {
      final style = ui.TextStyle(
        color: color,
        fontSize: 13,
        fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
      );
      final builder =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(textAlign: TextAlign.left, maxLines: 1),
            )
            ..pushStyle(style)
            ..addText(text);
      return builder.build()..layout(ui.ParagraphConstraints(width: maxWidth));
    });
  }

  void _clear() {
    for (final paragraph in _cache.values) {
      paragraph.dispose();
    }
    _cache.clear();
  }

  void dispose() => _clear();
}

// ---------------------------------------------------------------------------
// Nice Y-axis ranges. Ticks and the snapped range stay in base display units
// so the data pipeline and segment cache never see a rescale; only the labels
// render through the unit's SI-prefix rung.
// ---------------------------------------------------------------------------

/// Minimum spacing between axis ticks (logical px): [Size]-based density
/// instead of a fixed tick count, so wide/tall plots get more labels than a
/// phone without crowding either.
const double _kMinXTickPx = 48;
const double _kMinYTickPx = 32;

/// Breathing room demanded between neighboring X labels, on top of each
/// label's measured width (see [_fitTimeStep]).
const double _kLabelGapPx = 8;

typedef YAxisRange = ({
  double yMin,
  double yMax,
  double tickDelta,

  /// SI-prefix rung the tick labels are rendered in (ticks / factor + symbol).
  AxisRung rung,

  /// Label decimals: exactly enough to resolve the tick step in rung units.
  int decimals,
});

YAxisRange _computeYRange(
  double dataMin,
  double dataMax,
  DisplayUnit unit,
  double plotHeight,
) {
  // Guard only the exactly-degenerate span (a no-data derivative fold): the
  // SI-prefix rung keeps tiny-window labels readable, so there's no floor.
  final double max = dataMax <= dataMin ? dataMin + 1.0 : dataMax;

  // 1/2/5 tick delta sized so ticks land at least [_kMinYTickPx] apart.
  final tickDelta = _decadeStepCeil(
    (max - dataMin) * _kMinYTickPx / plotHeight,
  );

  // Snap yMin and yMax to tick boundaries
  final yMin = (dataMin / tickDelta).floor() * tickDelta;
  final yMax = (max / tickDelta).ceil() * tickDelta;

  final rung = unit.axisRung(math.max(yMin.abs(), yMax.abs()));
  final decimals = DisplayUnit.axisDecimalsFor(tickDelta / rung.factor);
  return (
    yMin: yMin,
    yMax: yMax,
    tickDelta: tickDelta,
    rung: rung,
    decimals: decimals,
  );
}

// ---------------------------------------------------------------------------
// Shared plot toolkit
// ---------------------------------------------------------------------------

/// Which axis [_drawAxis] renders: the grid-line direction and label
/// placement (X: vertical lines, labels centered below the plot; Y:
/// horizontal lines, labels centered vertically past the right edge).
enum _AxisOrientation { x, y }

/// Major cadence for tick [step]: the smallest [stepCeil] ladder rung at
/// least 5x step, expressed as a count of steps. The count lands at 5-10:
/// on the clock ladder the 5x rung keeps majors clock-aligned (whole 2-min
/// marks from a 20 s step, hour marks from a 10-min step), where bolding a
/// plain "every 5th tick" would land on round multiples of step like 100 s
/// or 25 min, which read as noise next to m:ss labels. The rung can never
/// collapse to step itself, so a tight zoom simply shows few or no majors
/// -- no minimum-count gate needed.
///
/// Majors are the ticks with k % period == 0 on the absolute tick grid
/// k * step, so the tick k == 0 (X: session start; Y: zero) is a major
/// whenever it is visible.
int _majorPeriod(double step, double Function(double target) stepCeil) {
  final superStep = stepCeil(5 * step);
  final period = (superStep / step).round();
  assert(
    (superStep - period * step).abs() < step * 1e-6,
    'superStep $superStep is not a multiple of step $step',
  );
  return period;
}

/// Fractional digits for [_fmtTick] at [step]: enough to resolve the step,
/// capped at 3 (ms).
int _timeDecimals(double step) =>
    step >= 1 ? 0 : (-(math.log(step) / math.ln10).floor()).clamp(1, 3);

/// Smallest clock-nice step for the time window [startSec, endSec) across
/// [extent] px: the lowest ladder rung keeping ticks at least
/// [_kMinXTickPx] apart, then bumped up the ladder until the labels
/// themselves fit with [_kLabelGapPx] to spare -- folded h:mm:ss and
/// fractional labels are wider than the 48 px floor and would overlap
/// (measured, not estimated; the width depends on which ticks are visible).
double _fitTimeStep(
  double startSec,
  double endSec,
  double extent,
  _LabelCache labels,
  Color textColor,
) {
  final spanSec = endSec - startSec;
  var step = _timeStepCeil(spanSec * _kMinXTickPx / extent);
  for (;;) {
    final period = _majorPeriod(step, _timeStepCeil);
    final decimals = _timeDecimals(step);
    double maxLabelW = 0;
    for (int k = (startSec / step).ceil(); k * step < endSec; k++) {
      final par = labels.prepare(
        _fmtTick(k * step, decimals),
        color: textColor,
        bold: k % period == 0,
      );
      if (par.longestLine > maxLabelW) maxLabelW = par.longestLine;
    }
    if (step * extent / spanSec >= maxLabelW + _kLabelGapPx) return step;
    step = _timeStepCeil(step * (1 + 1e-9)); // next ladder rung up
  }
}

/// Append one axis's grid lines and tick labels for the window
/// [windowStart, windowEnd] (X: seconds since session start; Y: display
/// units). [step] is the caller's tick step on the [stepCeil] ladder (X:
/// [_fitTimeStep]; Y: [YAxisRange.tickDelta]), [labelFor] formats a tick
/// value, and [posOf] maps one to its pixel along the axis.
///
/// Labeled ticks live on the absolute grid k * step, so they (and the
/// majors) hold still while the window slides. Majors (bold label,
/// [gridMajor]) are every [_majorPeriod]-th tick; other labeled ticks and
/// the half-step minor lines between them go to [gridMinor]. Indexing ticks
/// by k rather than accumulating keeps the major test exact and makes the
/// k == 0 tick literally 0.0 (no "-0.000" snap needed at the zero label).
///
/// [enumSlack] extends the drawn population past both window edges; X
/// passes one tick plus the live edge's worst lead jitter
/// ([_kLiveEdgeLeadMs]: a landing packet rewinds the wall-clock lead), so a
/// rolling window micro-oscillating across an edge tick slides it in and
/// out instead of toggling it per frame. The labels then clip to the label
/// strip so slack labels don't bleed into the plot. Y snaps its range to
/// tick boundaries and passes 0: its ticks are always in range.
void _drawAxis(
  Canvas canvas,
  Path gridMinor,
  Path gridMajor,
  Size graphSz, {
  required _AxisOrientation orientation,
  required double windowStart,
  required double windowEnd,
  required double step,
  required double Function(double target) stepCeil,
  required String Function(double tick) labelFor,
  required double Function(double value) posOf,
  double enumSlack = 0.0,
  required bool showLabels,
  required _LabelCache labels,
  Color textColor = Colors.black,
}) {
  final period = _majorPeriod(step, stepCeil);
  final lo = windowStart - enumSlack;
  // Inclusive end, with room for fp noise: a tick exactly at the snapped or
  // slacked edge (Y's bounds) draws rather than dropping out.
  final hi = windowEnd + enumSlack + step * 0.01;

  void gridLine(double pos, {required bool major}) {
    final path = major ? gridMajor : gridMinor;
    switch (orientation) {
      case _AxisOrientation.x:
        path
          ..moveTo(pos, 0)
          ..lineTo(pos, graphSz.height);
      case _AxisOrientation.y:
        path
          ..moveTo(0, pos)
          ..lineTo(graphSz.width, pos);
    }
  }

  // Measure the labels before installing the label-strip clip.
  double maxLabelH = 0;
  double maxLabelW = 0;
  final clipped = showLabels && enumSlack > 0;
  if (showLabels) {
    for (int k = (lo / step).ceil(); k * step <= hi; k++) {
      final par = labels.prepare(
        labelFor(k * step),
        color: textColor,
        bold: k % period == 0,
      );
      if (par.longestLine > maxLabelW) maxLabelW = par.longestLine;
      if (par.height > maxLabelH) maxLabelH = par.height;
    }
    if (clipped) {
      canvas.save();
      canvas.clipRect(switch (orientation) {
        _AxisOrientation.x => Rect.fromLTWH(
          0,
          graphSz.height,
          graphSz.width,
          maxLabelH + 4,
        ),
        _AxisOrientation.y => Rect.fromLTWH(
          graphSz.width,
          0,
          maxLabelW + 4,
          graphSz.height,
        ),
      });
    }
  }

  for (int k = (lo / step).ceil(); k * step <= hi; k++) {
    final major = k % period == 0;
    final pos = posOf(k * step);
    gridLine(pos, major: major);
    if (showLabels) {
      final par = labels.prepare(
        labelFor(k * step),
        color: textColor,
        bold: major,
      );
      switch (orientation) {
        case _AxisOrientation.x:
          canvas.drawParagraph(
            par,
            Offset(pos - par.longestLine / 2, graphSz.height + 2),
          );
        case _AxisOrientation.y:
          canvas.drawParagraph(
            par,
            Offset(graphSz.width + 4, pos - par.height / 2),
          );
      }
    }
  }
  if (clipped) canvas.restore();

  // Half-step minor lines. Index by j so the overlap test is exact: the
  // even multiples of minorStep are the labeled ticks themselves, and
  // skipping them leaves emphasis to the tick lines, not a double stroke.
  final minorStep = step / 2;
  for (int j = (lo / minorStep).ceil(); j * minorStep <= hi; j++) {
    if (j % 2 == 0) continue;
    gridLine(posOf(j * minorStep), major: false);
  }
}

void _drawZeroBaseline(
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

/// Draws a diagonal warning hatch pattern over the [SampleStorage.gaps]
/// ranges visible in the window (regions where packets were dropped).
void _drawMissingDataHatching(
  Canvas canvas,
  Size graphSz, {
  required double viewStart,
  required double viewEnd,
  required SampleStorage data,
  required Color color,
}) {
  final gaps = data.gaps;
  if (gaps.isEmpty) return;

  final (sScanStart, sScanEnd) = data.clampToRetained(
    viewStart.floor(),
    viewEnd.ceil(),
  );
  if (sScanStart >= sScanEnd) return;

  final viewSamples = viewEnd - viewStart;
  if (viewSamples <= 0) return;

  double xOf(int sampleIdx) =>
      (sampleIdx - viewStart) * graphSz.width / viewSamples;

  final hatchPen = Paint()
    ..color = color.withAlpha(60)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;
  final bgPen = Paint()
    ..color = color.withAlpha(20)
    ..style = PaintingStyle.fill;

  void drawHatchRegion(int startIdx, int endIdx) {
    final xStart = xOf(startIdx);
    final xEnd = xOf(endIdx);

    const double spacing = 8.0;

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
        hatchPen,
      );
    }

    canvas.drawRect(Rect.fromLTRB(xStart, 0, xEnd, graphSz.height), bgPen);

    canvas.restore();
  }

  for (final (gs, ge) in gaps.rangesIn(sScanStart, sScanEnd)) {
    drawHatchRegion(gs, ge);
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
@visibleForTesting
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

  int get _capacity => _buf.length;

  void add(double x, double y) {
    _buf[_len++] = x;
    _buf[_len++] = y;
  }

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

  /// Drop the preserved tail after a [flush]: the primitive ends here, so the
  /// next [add] starts a fresh polyline instead of bridging the gap. The
  /// break idiom is `flush(); reset();` — [reset] alone would silently drop
  /// un-emitted vertices.
  void reset() {
    _len = 0;
  }
}

/// The (average polyline, min/max envelope fill) [VertexBatcher] pair shared
/// by the envelope renderers. Both batchers reuse one [Paint], restyled per
/// flush.
({VertexBatcher avg, VertexBatcher env}) _envelopeBatchers(
  Canvas canvas, {
  required Color avgColor,
  required double avgStrokeWidth,
  required Color envColor,
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
      canvas.drawRawPoints(ui.PointMode.polygon, view, pen);
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
      canvas.drawVertices(vertices, ui.BlendMode.srcOver, pen);
      vertices.dispose();
    },
  );

  return (avg: avg, env: env);
}

/// Render one channel as a min/avg/max envelope across [graphW] pixel columns:
/// each block's samples are reduced to min/avg/max and projected with
/// [valueToY]; the envelope is filled at low alpha, the average stroked on top.
///
/// Blocks are anchored to absolute sample indices, so the geometry lands on the
/// same pixels regardless of scroll and the segment cache can bake it once. A
/// bucketed [series] switches to [reduceBlockBuckets] when a block spans >= 2
/// buckets (see its doc for the accuracy and ring-wrap details).
///
/// Gap ink is clipped by [_paintEnvelopeDataLayer]; the exact and bucket paths
/// differ only at gap edges. Vertices flush in <=4096-float chunks to stay
/// within the web stack-allocation limit.
void _drawChannelEnvelope(
  Canvas canvas, {
  required Color color,
  required double graphW,
  required int viewStart,
  required double viewSamples,
  required int totalSamples,
  required int firstUsableSample,
  required EnvelopeSeries series,
  required double Function(double value) valueToY,
  required int clipEnvelopeSamples,
  double avgStrokeWidth = 1.5,
  int avgAlpha = 255,
  int envAlpha = 60,
}) {
  final (avg: avg, env: env) = _envelopeBatchers(
    canvas,
    avgColor: color.withAlpha(avgAlpha),
    avgStrokeWidth: avgStrokeWidth,
    envColor: color.withAlpha(envAlpha),
  );

  final int blockSize = _blockSizeFor(viewSamples, graphW);

  // Buckets pay off (and stay accurate) once a block spans >= 2 buckets.
  final buckets = series.buckets;
  final bool useBuckets = blockSize >= 2 * buckets.bucketSize;

  // Anchored to absolute sample 0, not viewStart, so caching stays
  // scroll-invariant.
  final int startBlock = (math.max(viewStart, firstUsableSample) / blockSize)
      .floor();
  final int endBlock = (totalSamples / blockSize).ceil();

  for (int k = startBlock; k < endBlock; k++) {
    final int sStart = k * blockSize;
    final int sEnd = math.min(
      sStart + blockSize,
      totalSamples,
    ); // last block may be short

    final int drawStart = math.max(sStart, firstUsableSample);
    if (drawStart >= sEnd) continue;
    // Short only at the trailing block or a firstUsableSample clip.
    assert(
      sEnd - drawStart >= 1 && sEnd - drawStart <= blockSize,
      'block [$drawStart, $sEnd) has bad size for blockSize $blockSize',
    );

    final BlockReduction r = useBuckets
        ? reduceBlockBuckets(series, drawStart, sEnd)
        : reduceBlockExact(series.sampleAt, drawStart, sEnd);

    if (r.count == 0) {
      // Break the polyline at a fully-dropped block: flush, then reset so the
      // next valid block starts a fresh primitive instead of bridging the gap.
      env.flush();
      env.reset();
      avg.flush();
      avg.reset();
      continue;
    }

    final avgY = valueToY(r.sum / r.count);
    final minY = valueToY(r.min);
    final maxY = valueToY(r.max);

    // Segment-local x: a baked segment passes its own start as viewStart.
    final double xPos = (sStart - viewStart) * graphW / viewSamples;
    final double nextXPos = (sEnd - viewStart) * graphW / viewSamples;

    avg.add(xPos, avgY);

    if (sStart < clipEnvelopeSamples) {
      env.add(xPos, maxY);
      env.add(xPos, minY);
      env.add(nextXPos, maxY);
      env.add(nextXPos, minY);

      if (env.wouldOverflow(8)) env.flush();
    }

    if (avg.wouldOverflow(2)) avg.flush();
  }

  env.flush();
  avg.flush();
}

/// The tared-force rendering recipe for one channel: the exact per-sample
/// evaluator (gap samples NaN, breaking the polyline — see
/// [SampleStorageQueries.rawValueAt]) plus its bucket acceleration. The
/// [EnvelopeSeries.bucketed] invariants hold by construction: the bucket
/// raw-to-display map and the per-sample evaluator are the same conversion
/// (the map is monotone, so raw bucket extremes map exactly to display
/// extremes; only the bucket MEAN is off, by the board's nonlinearity).
/// Shared by the force graph and the minimap so both plot the identical
/// series.
EnvelopeSeries _taredEnvelopeSeries(
  GraphDataSource data,
  _ConvertedChannel bound,
) => EnvelopeSeries.bucketed(
  sampleAt: (j) => bound.netMap(data.rawValueAt(bound.channel, j)),
  buckets: data.valueBucketsFor(bound.channel),
  rawToDisplay: bound.netMap,
);

/// Fold the raw extremes of [channels] over `[start, end)` (already clamped
/// to the source's usable range). [seriesFor] yields a channel's bucket
/// aggregates and exact evaluator, or null when the channel has no data;
/// [adjust] maps each folded bound per channel (tare offset, display scale).
/// BOTH adjusted bounds feed each end of the range, so a negative display
/// multiplier can't invert it. Returns null when no channel covers a sample.
(double, double)? _foldChannelExtremes<T>(
  Iterable<T> channels,
  int start,
  int end,
  (BucketSeries buckets, double Function(int i) rawAt)? Function(T channel)
  seriesFor,
  double Function(double raw, T channel) adjust,
) {
  double? lo, hi;
  for (final ch in channels) {
    final series = seriesFor(ch);
    if (series == null) continue;
    // Gap samples hold a previous real value, so they can never extend
    // the range: no exclusion needed.
    final ext = windowedExtremes(series.$1, start, end, series.$2);
    if (ext == null) continue;
    for (final v in [adjust(ext.$1, ch), adjust(ext.$2, ch)]) {
      if (lo == null || v < lo) lo = v;
      if (hi == null || v > hi) hi = v;
    }
  }
  // lo and hi are always assigned together; null means no channel folded.
  return (lo == null) ? null : (lo, hi!);
}

/// Paint the segment-cached envelope data layer for the window
/// [viewStart, viewStart + viewSpan) mapped to x in [0, gw): the pipeline
/// shared by the force graph, derivative graph, and minimap.
///
/// [seriesFor] returns the per-channel rendering recipe. Cache keying: the
/// display [unit], calibration version, and [tares] are destructive (never
/// blitted once stale); the channel list is the remap key (stale segments keep
/// blitting as ghosts while swept); a data-generation change clears the cache.
/// See the staleness model on [SegmentedGraphCache].
///
/// Returns true when bake work remains; the owner should schedule another
/// frame.
@useResult
bool _paintEnvelopeDataLayer(
  Canvas canvas, {
  required SegmentedGraphCache cache,
  required GraphDataSource data,
  required List<_ConvertedChannel> channels,
  required List<double?> tares,
  required DisplayUnit unit,
  required double gw,
  required double gh,
  required double dpr,
  required double viewStart,
  required double viewSpan,
  required double yMin,
  required double yMax,
  required int firstUsableSample,
  required EnvelopeSeries Function(_ConvertedChannel channel) seriesFor,
  double avgStrokeWidth = 1.5,
  int avgAlpha = 255,
  int envAlpha = 60,
}) {
  final totalSamples = data.totalSamples;

  double valueToY(double val) => gh - (val - yMin) * gh / (yMax - yMin);

  final int blockSize = _blockSizeFor(viewSpan, gw);
  final double blockPx = blockSize * gw / viewSpan;

  // The bake render clamps content to firstUsableSample (the ring can't
  // serve evicted samples), but that clamp is deliberately NOT in the
  // segment keys: keying on it would churn every packet after a ring wrap
  // and force full rebakes of unchanged segments. Instead clip the whole
  // draw (bakes and blits alike) at the retention edge so a stale blit
  // can't show evicted-sample ink a fresh draw would omit. A no-op
  // whenever the window starts at or inside usable data.
  final usableX = (firstUsableSample - viewStart) * gw / viewSpan;
  if (usableX > 0) {
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(usableX, -1e9, 2e9, 2e9));
  }
  final workRemains = cache.paint(canvas, (
    generation: data.dataGeneration,
    destructiveKey: [unit, data.calibrationVersion, ...tares],
    remapKey: [for (final bound in channels) bound.channel],
    gw: gw,
    gh: gh,
    dpr: dpr,
    viewStart: viewStart,
    viewSpan: viewSpan,
    yMin: yMin,
    yMax: yMax,
    totalSamples: totalSamples,
    // Bakes stop the join slack behind the data edge so their join block is
    // complete (see [joinBlockEnd]).
    bakeableSamples: math.max(
      0,
      totalSamples - _kJoinBlockSlackBlocks * blockSize,
    ),
    // One block of overshoot can be many px when zoomed past 1 sample/px.
    hPad: math.max(kSegmentImagePad, blockPx + 2),
    vPad: kSegmentImagePad,
    render: (cCanvas, start, end, texW) {
      // The polyline overshoots the segment end into its join block so the
      // line reaches the seam with the neighbor's slope; that block is
      // reduced over its FULL range so the join vertex matches the
      // neighbor's.
      final int limit = math.min(joinBlockEnd(end, blockSize), totalSamples);

      // Clip data ink out of gap x-ranges (the hatching drawn by the chrome
      // is the only marker there). A baked segment's gap set is frozen even
      // though gaps are NOT append-only: new gaps land at the live edge,
      // past the 2-block bake horizon, and pruneBefore drops gaps only left
      // of the retention edge, which the draw-time clip above hides.
      final clip = _gapClipPath(data.gaps, start, limit, gw / viewSpan);
      if (clip != null) {
        cCanvas.save();
        cCanvas.clipPath(clip);
      }
      for (final bound in channels) {
        _drawChannelEnvelope(
          cCanvas,
          color: bound.color,
          graphW: gw,
          viewStart: start,
          viewSamples: viewSpan,
          totalSamples: limit,
          firstUsableSample: firstUsableSample,
          series: seriesFor(bound),
          valueToY: valueToY,
          clipEnvelopeSamples: end,
          avgStrokeWidth: avgStrokeWidth,
          avgAlpha: avgAlpha,
          envAlpha: envAlpha,
        );
      }
      if (clip != null) cCanvas.restore();
      return (end - start) * gw / viewSpan;
    },
  ));
  if (usableX > 0) canvas.restore();
  return workRemains;
}

/// Everything-except-gaps clip for [start, end) under x = (s - start) *
/// pxPerSample, or null when no gap overlaps (the common case). One huge rect
/// with even-odd gap holes; ranges are disjoint.
Path? _gapClipPath(GapList gaps, int start, int end, double pxPerSample) {
  if (gaps.isEmpty) return null;
  const double big = 1e9; // covers any pad/overdraw around the plot area
  Path? path;
  for (final (gs, ge) in gaps.rangesIn(start, end)) {
    path ??= Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(const Rect.fromLTRB(-big, -big, big, big));
    path.addRect(
      Rect.fromLTRB(
        (gs - start) * pxPerSample,
        -big,
        (ge - start) * pxPerSample,
        big,
      ),
    );
  }
  return path;
}

// ---------------------------------------------------------------------------
// Windowed time-series graph painters (force, derivative)
// ---------------------------------------------------------------------------

/// Lead past the newest sample: one packet period, so arrival jitter reads as
/// a brief freeze rather than a backward lurch.
const double _kLiveEdgeLeadMs = 20;

/// Also cap the lead at this fraction of the visible span, so at narrow spans
/// a full packet of lead can't detach the trace end from the plot's right edge.
const double _kLiveEdgeLeadSpanFraction = 0.05;

/// Stop the smooth-scroll ticker once the stream is this stale: past the worst
/// normal inter-packet gap, so it never churns mid-stream.
const int _kTickerStallMs = 100;

/// The live-follow window's right edge in fractional samples: the newest
/// sample count plus wall-clock elapsed since it landed, capped by
/// [_kLiveEdgeLeadMs] and [_kLiveEdgeLeadSpanFraction] of [spanSamples].
double _liveEdge(GraphDataSource data, int spanSamples) {
  final int total = data.totalSamples;
  final DateTime? last = data.lastDataAt;
  if (last == null) return total.toDouble();
  final double elapsedMs =
      DateTime.now().difference(last).inMicroseconds / 1000.0;
  final double leadCapMs = math.min(
    _kLiveEdgeLeadMs,
    _kLiveEdgeLeadSpanFraction * spanSamples / data.sampleRate * 1000.0,
  );
  return total + elapsedMs.clamp(0.0, leadCapMs) * data.sampleRate / 1000.0;
}

/// Common painter prologue shared by the force and derivative graphs: translate
/// into the plot area, compute the plot [Size], draw the frame border, and
/// resolve the visible window.
///
/// Returns null when there is nothing to draw (degenerate size, too few
/// samples, or a degenerate window). [minSamples] is the smallest sample count
/// the graph needs (1 for force, 2 for the derivative's first difference).
typedef _GraphLayout = ({
  Size graphSz,
  double viewStart,
  double viewEnd,
  double viewSamples,
});

@useResult
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

  canvas.translate(_kGraphLeftSpace, topSpace);
  final graphSz = Size(
    size.width - _kGraphLeftSpace - kGraphRightSpace,
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
  );
  // Rolling live windows anchor their right edge to the fractional live
  // edge so the trace scrolls smoothly between packets. Data-pinned views
  // (parked, or live "everything") keep their integer edges: they are pure
  // functions of the data on hand, and floating them would let the lead's
  // per-packet rewind shake every tick and label by the lead's pixel width
  // (most visible at squeezed full-view spans, where nothing else moves).
  final rollingSpan = ctrl.lockedLiveSpan;
  double viewStartF = viewStart.toDouble();
  double viewEndF = viewEnd.toDouble();
  if (rollingSpan != null) {
    viewEndF = _liveEdge(data, rollingSpan);
    viewStartF = viewEndF - rollingSpan;
  }
  final viewSamples = viewEndF - viewStartF;
  if (viewSamples < minSamples) return null;

  return (
    graphSz: graphSz,
    viewStart: viewStartF,
    viewEnd: viewEndF,
    viewSamples: viewSamples,
  );
}

/// Shared engine for the windowed time-series graphs (force, derivative).
///
/// Handles the pipeline common to both: frame setup, Y-range for the visible
/// window, axes/grid, zero baseline, missing-data hatching, and the
/// segment-cached envelope rendering. Subclasses define the series being
/// plotted -- [series] (per-channel [EnvelopeSeries]), [computeYRange],
/// [yTickLabel] -- plus layout tweaks and cache-key extras.
abstract class _TimeSeriesGraphPainter extends CustomPainter {
  final GraphDataSource _data;
  final DisplayUnit _unit;
  final GraphController _ctrl;

  /// Series to plot (channels bound to [_unit]).
  final List<_ConvertedChannel> _channels;
  final SegmentedGraphCache cache;
  final ColorScheme colorScheme;

  /// Device pixel ratio used when rasterizing segment textures.
  final double dpr;

  /// Axis-label paragraph cache, owned (and disposed) by the host [State].
  final _LabelCache labels;

  /// Drives the rolling segment bakes: a repaint listenable for this painter
  /// and the scheduler for extra frames when bake work remains (rolling
  /// bakes must complete even for static sources whose
  /// [GraphDataSource.repaint] never fires).
  final BakePump bakePump;

  _TimeSeriesGraphPainter(
    this._data,
    this._ctrl, {
    required DisplayUnit unit,
    required List<_ConvertedChannel> channels,
    required Listenable vsync,
    required this.cache,
    required this.colorScheme,
    required this.dpr,
    required this.labels,
    required this.bakePump,
  }) : _unit = unit,
       _channels = channels,
       super(
         repaint: Listenable.merge([_data.repaint, _ctrl, bakePump, vsync]),
       );

  // --- Layout hooks --------------------------------------------------------

  double get topSpace;

  /// Whether to draw time labels below the X axis.
  bool get showXLabels => true;

  /// Offset from [GraphDataSource.oldestSample] of the first sample the
  /// series can be evaluated at (1 for a first difference).
  int get firstSampleOffset => 0;

  // --- Series hooks --------------------------------------------------------

  /// Returns the rendering recipe for [channel]: the per-sample evaluator
  /// (value at an absolute sample index, in display units; NaN marks a
  /// missing sample) plus optional bucket acceleration (see
  /// [EnvelopeSeries.bucketed] for the invariants it must satisfy).
  EnvelopeSeries series(_ConvertedChannel channel);

  /// Y-axis range (display units) for the visible window. Null when no
  /// active channel is plottable in the window: the graph paints blank.
  /// [plotHeight] sizes the tick density (see [_kMinYTickPx]).
  YAxisRange? computeYRange(
    double viewStart,
    double viewEnd,
    double plotHeight,
  );

  String yTickLabel(double tick, YAxisRange yRange);

  /// Per-channel tares mixed into the segment-cache destructive key. The
  /// derivative returns none: a difference cancels them.
  List<double?> cacheKeyTares() => const [];

  /// Optional chrome drawn after the axes, before the data lines. [yRange]
  /// and [valueToY] are this paint pass's axis mapping, [viewStart]/
  /// [viewEnd] the visible sample window.
  void drawOverlay(
    Canvas canvas,
    Size graphSz,
    YAxisRange yRange,
    double Function(double value) valueToY,
    double viewStart,
    double viewEnd,
  ) {}

  /// Optional chrome drawn in the right gutter, before the Y-axis labels, so
  /// the labels sit on top of it.
  void drawGutterChrome(
    Canvas canvas,
    Size graphSz,
    double Function(double value) valueToY,
  ) {}

  @nonVirtual
  @override
  void paint(Canvas canvas, Size size) {
    final layout = _setupGraphFrame(
      canvas,
      size,
      _data,
      _ctrl,
      topSpace: topSpace,
      bottomSpace: showXLabels ? _kGraphBottomSpace : 4,
      minSamples: 1 + firstSampleOffset,
      frameColor: colorScheme.primary.withAlpha(150),
    );
    if (layout == null) return;

    final graphSz = layout.graphSz;
    final viewStart = layout.viewStart;
    final viewEnd = layout.viewEnd;
    final viewSamples = layout.viewSamples;

    final oldestSample = _data.oldestSample;

    // A parked window wholly past the retention edge (parked, then eviction
    // passed it by): the ring holds no sample in it. Any Y range here would
    // be invented, so no axes -- a bare frame and the reason. The LIVE
    // button (the workspace's overlay) is the way out. Partially evicted
    // windows draw normally below, clipped at the retention head.
    if (viewEnd <= oldestSample + firstSampleOffset) {
      final retentionMin = (_data.maxViewableSamples / 60 / _data.sampleRate)
          .round();
      final parBuilder = ui.ParagraphBuilder(ui.ParagraphStyle(maxLines: 1))
        ..pushStyle(
          ui.TextStyle(
            color: colorScheme.onSurface.withAlpha(150),
            fontSize: 13,
          ),
        )
        ..addText('Beyond $retentionMin min history');
      final par = parBuilder.build()
        ..layout(const ui.ParagraphConstraints(width: double.infinity));
      canvas.drawParagraph(
        par,
        Offset(
          math.max(0, (graphSz.width - par.longestLine) / 2),
          (graphSz.height - par.height) / 2,
        ),
      );
      par.dispose();
      return;
    }

    final yRange = computeYRange(viewStart, viewEnd, graphSz.height);
    if (yRange == null) return;

    // Canvas y grows downward, so the axis is flipped: yMax maps to 0.
    double valueToY(double val) {
      return graphSz.height -
          (val - yRange.yMin) * graphSz.height / (yRange.yMax - yRange.yMin);
    }

    // -- Grid and labels --
    drawGutterChrome(canvas, graphSz, valueToY);

    final gridMinor = Path();
    final gridMajor = Path();
    final sampleRate = _data.sampleRate.toDouble();
    final startSec = viewStart / sampleRate;
    final endSec = viewEnd / sampleRate;
    final timeStep = _fitTimeStep(
      startSec,
      endSec,
      graphSz.width,
      labels,
      colorScheme.onSurface,
    );
    _drawAxis(
      canvas,
      gridMinor,
      gridMajor,
      graphSz,
      orientation: _AxisOrientation.x,
      windowStart: startSec,
      windowEnd: endSec,
      step: timeStep,
      stepCeil: _timeStepCeil,
      labelFor: (sec) => _fmtTick(sec, _timeDecimals(timeStep)),
      posOf: (sec) =>
          (sec - startSec) * sampleRate * graphSz.width / viewSamples,
      enumSlack: timeStep + _kLiveEdgeLeadMs / 1000.0,
      showLabels: showXLabels,
      labels: labels,
      textColor: colorScheme.onSurface,
    );
    _drawAxis(
      canvas,
      gridMinor,
      gridMajor,
      graphSz,
      orientation: _AxisOrientation.y,
      windowStart: yRange.yMin,
      windowEnd: yRange.yMax,
      step: yRange.tickDelta,
      stepCeil: _decadeStepCeil,
      labelFor: (tick) => yTickLabel(tick, yRange),
      posOf: valueToY,
      showLabels: true,
      labels: labels,
      textColor: colorScheme.onSurface,
    );
    final gridMinorPen = Paint()
      ..color = colorScheme.onSurface.withAlpha(45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.2;
    // Major lines echo the bold labels: same tiers on screen. The zero
    // baseline ([_drawZeroBaseline], alpha 130 @ 0.8) stays a tier above.
    final gridMajorPen = Paint()
      ..color = colorScheme.onSurface.withAlpha(80)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.4;
    // Clip to the plot: the X axis populates ticks one edge-slack past each
    // side (see [_drawAxis]'s enumSlack; its labels clip to the label strip).
    canvas.save();
    canvas.clipRect(Offset.zero & graphSz);
    canvas.drawPath(gridMinor, gridMinorPen);
    canvas.drawPath(gridMajor, gridMajorPen);
    canvas.restore();

    _drawZeroBaseline(
      canvas,
      graphSz,
      yRange,
      valueToY,
      colorScheme.onSurface.withAlpha(130),
    );

    _drawMissingDataHatching(
      canvas,
      graphSz,
      viewStart: viewStart,
      viewEnd: viewEnd,
      data: _data,
      color: colorScheme.error,
    );

    drawOverlay(canvas, graphSz, yRange, valueToY, viewStart, viewEnd);

    // -- Data lines (segment-cached envelope) --
    final workRemains = _paintEnvelopeDataLayer(
      canvas,
      cache: cache,
      data: _data,
      channels: _channels,
      tares: cacheKeyTares(),
      unit: _unit,
      gw: graphSz.width,
      gh: graphSz.height,
      dpr: dpr,
      viewStart: viewStart,
      viewSpan: viewSamples,
      yMin: yRange.yMin,
      yMax: yRange.yMax,
      firstUsableSample: oldestSample + firstSampleOffset,
      seriesFor: series,
    );
    if (workRemains) bakePump.schedule();
  }

  @nonVirtual
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Force graph: each channel's tared value in the selected display unit.
/// The limit chrome (rail and load-cell zone bars) draws in
/// [drawGutterChrome], in the right gutter under the axis labels.
class _ForceGraphPainter extends _TimeSeriesGraphPainter {
  @override
  final bool showXLabels;

  _ForceGraphPainter(
    super.data,
    super.ctrl, {
    this.showXLabels = true,
    required super.unit,
    required super.channels,
    required super.vsync,
    required super.cache,
    required super.colorScheme,
    required super.dpr,
    required super.labels,
    required super.bakePump,
  });

  @override
  double get topSpace => 4;

  /// Fixed axis when every plotted channel is unitless (a normalized blend):
  /// it's a ±1 coordinate, and autoscaling would make stationary noise read
  /// as motion. Mixed force+unitless selections keep the window fit.
  static const YAxisRange _kUnitlessRange = (
    yMin: -1.1,
    yMax: 1.1,
    tickDelta: 0.5,
    rung: (factor: 1.0, symbol: ''),
    decimals: 1,
  );

  @override
  List<double?> cacheKeyTares() => [
    for (final bound in _channels) ...bound.cacheTares,
  ];

  @override
  EnvelopeSeries series(_ConvertedChannel channel) =>
      _taredEnvelopeSeries(_data, channel);

  @override
  YAxisRange? computeYRange(
    double viewStart,
    double viewEnd,
    double plotHeight,
  ) {
    if (_channels.isNotEmpty && _channels.every((c) => c.unitless)) {
      return _kUnitlessRange;
    }
    // [windowedRawExtremes] folds full buckets and scans only the partial
    // head/tail: O(window / bucketSize). No minimum-range floor; flat data
    // hits the degeneracy guard in [_computeYRange].
    final unit = _unit;
    final start = viewStart.floor();
    final end = viewEnd.ceil();

    double yMin = double.infinity;
    double yMax = double.negativeInfinity;
    for (final bound in _channels) {
      final ext = _data.windowedRawExtremes(bound.channel, start, end);
      if (ext == null) continue;
      yMin = math.min(yMin, bound.netMap(ext.$1));
      yMax = math.max(yMax, bound.netMap(ext.$2));
    }
    // No plotted channel has data in the window: paint blank.
    if (!yMin.isFinite || !yMax.isFinite) return null;

    return _computeYRange(yMin, yMax, unit, plotHeight);
  }

  /// Limit bars in the right gutter: one column per hardware channel, a rail
  /// zone from the ADC rail to the plot edge and (with a load cell) a
  /// capacity zone from 100% capacity to the rail. Projected through the
  /// unit converter net of tare (see [ChannelConverter.diffMap]); clamping
  /// to the plot rect collapses off-view and empty zones. Derived channels
  /// have no rails of their own.
  @override
  void drawGutterChrome(
    Canvas canvas,
    Size graphSz,
    double Function(double value) valueToY,
  ) {
    final railPaint = Paint()..color = colorScheme.error.withAlpha(48);
    final cellPaint = Paint()..color = colorScheme.error.withAlpha(22);
    const colW = kGraphRightSpace / kAdcChannelCount;

    for (final bound in _channels) {
      final hw = bound.hardwareIndex;
      if (hw == null) continue;
      final cell = bound.loadCell;
      final span = bound.sensitivityCountsPerMvV;
      // Net display value at 100% cell capacity; null without a cell or the
      // board sensitivity to size it.
      final cellNet = cell != null && span != null
          ? bound.diffMap(cell.sensitivityMvV * span)
          : null;
      final left = graphSz.width + colW * hw;
      for (final positive in [true, false]) {
        final clipRaw = positive
            ? ChannelLimits.clipRawPos
            : ChannelLimits.clipRawNeg;
        final railY = valueToY(
          bound.netMap(clipRaw.toDouble()),
        ).clamp(0.0, graphSz.height);
        final railBar = positive
            ? Rect.fromLTRB(left, 0.0, left + colW, railY)
            : Rect.fromLTRB(left, railY, left + colW, graphSz.height);
        if (railBar.height > 0) canvas.drawRect(railBar, railPaint);

        if (cellNet == null) continue;
        final cellY = valueToY(
          positive ? cellNet : -cellNet,
        ).clamp(0.0, graphSz.height);
        final cellBar = positive
            ? Rect.fromLTRB(left, railY, left + colW, cellY)
            : Rect.fromLTRB(left, cellY, left + colW, railY);
        if (cellBar.height > 0) canvas.drawRect(cellBar, cellPaint);
      }
    }
  }

  @override
  String yTickLabel(double tick, YAxisRange yRange) => _formatTickLabel(
    tick / yRange.rung.factor,
    yRange.rung.symbol,
    yRange.decimals,
  );
}

/// Derivative graph: the first difference of each channel, scaled to display
/// units per second.
class _DerivativeGraphPainter extends _TimeSeriesGraphPainter {
  _DerivativeGraphPainter(
    super.data,
    super.ctrl, {
    required super.unit,
    required super.channels,
    required super.vsync,
    required super.cache,
    required super.colorScheme,
    required super.dpr,
    required super.labels,
    required super.bakePump,
  });

  @override
  double get topSpace => 2;

  @override
  int get firstSampleOffset => 1; // first difference needs sample j-1

  /// A first difference cancels tare — EXCEPT for normalized channels: the
  /// ratio bakes member tares in, so their diff series changes on a tare
  /// edge and the cache must hear it.
  @override
  List<double?> cacheKeyTares() => [
    for (final bound in _channels)
      if (bound.unitless) ...bound.cacheTares,
  ];

  /// Per-sample first difference in raw counts (gap-edge NaN lives in
  /// [SampleStorageQueries.diffDefinedAt]).
  double Function(int j) _rawDiffAt(int channel) =>
      (j) => _data.rawDiffAt(channel, j);

  /// Per-sample first difference in display units per second: the channel's
  /// net map differenced across adjacent samples (exact under the piecewise
  /// map; tare cancels). NaN marks gap edges, breaking the polyline.
  double Function(int j) _sampleAt(_ConvertedChannel bound) {
    final net = bound.netMap;
    final rate = _data.sampleRate.toDouble();
    final ch = bound.channel;
    return (j) {
      if (!_data.diffDefinedAt(j)) return double.nan;
      return (net(_data.rawAt(ch, j).toDouble()) -
              net(_data.rawAt(ch, j - 1).toDouble())) *
          rate;
    };
  }

  /// Raw-diff -> display-units-per-second map for the bucket fast path of
  /// [bound] (terminal-slope based, see [ChannelConverter.diffMap]).
  double Function(double rawDiff) _diffDisplayFor(_ConvertedChannel bound) {
    final diffMap = bound.diffMap;
    final rate = _data.sampleRate.toDouble();
    return (diff) => diffMap(diff) * rate;
  }

  @override
  EnvelopeSeries series(_ConvertedChannel channel) => EnvelopeSeries.bucketed(
    sampleAt: _sampleAt(channel),
    buckets: _data.diffBucketsFor(channel.channel),
    rawToDisplay: _diffDisplayFor(channel),
  );

  /// Every plotted channel unitless: the axis is pure per-second rate, no
  /// unit rung.
  bool get _allUnitless =>
      _channels.isNotEmpty && _channels.every((c) => c.unitless);

  @override
  YAxisRange? computeYRange(
    double viewStart,
    double viewEnd,
    double plotHeight,
  ) {
    // [windowedExtremes] folds full buckets and scans only the partial
    // head/tail: O(window / bucketSize).
    double dMin = 0;
    double dMax = 0;
    bool first = true;
    final (startI, endI) = _data.clampToRetained(
      viewStart.floor(),
      viewEnd.ceil(),
    );
    // The first difference at index 0 has no predecessor.
    final from = math.max(startI, _data.oldestSample + firstSampleOffset);

    void fold(double d) {
      if (first || d < dMin) dMin = d;
      if (first || d > dMax) dMax = d;
      first = false;
    }

    // Each channel folds via the bucket fast path through its own diff map
    // (monotone, so both bounds fold safely).
    final ext = _foldChannelExtremes(_channels, from, endI, (bound) {
      return (_data.diffBucketsFor(bound.channel), _rawDiffAt(bound.channel));
    }, (raw, bound) => _diffDisplayFor(bound)(raw));
    if (ext != null) {
      fold(ext.$1);
      fold(ext.$2);
    }

    if (_allUnitless) {
      // Same layout as a unit rung, with the identity scaling baked in.
      final span = math.max(dMax - dMin, 1e-12);
      final delta = _decadeStepCeil(span / 5);
      final y0 = (dMin / delta).floor() * delta;
      var y1 = (dMax / delta).ceil() * delta;
      if (y1 <= y0) y1 = y0 + delta; // flat trace: still a drawable span
      return (
        yMin: y0,
        yMax: y1,
        tickDelta: delta,
        rung: (factor: 1.0, symbol: ''),
        decimals: delta >= 1 ? 0 : 2,
      );
    }
    return _computeYRange(dMin, dMax, _unit, plotHeight);
  }

  @override
  String yTickLabel(double tick, YAxisRange yRange) =>
      '${_formatTickValue(tick / yRange.rung.factor, yRange.decimals)}/s';

  @override
  void drawOverlay(
    Canvas canvas,
    Size graphSz,
    YAxisRange yRange,
    double Function(double value) valueToY,
    double viewStart,
    double viewEnd,
  ) {
    final dLabel = labels.prepare(
      'dF/dt (${yRange.rung.symbol}/s)',
      color: colorScheme.onSurface.withAlpha(150),
    );
    canvas.drawParagraph(dLabel, const Offset(4, 2));
  }
}

// ---------------------------------------------------------------------------
// FFT pane
//
// The spectrum of the last N samples of the visible time window, per
// selected channel. Not a [_TimeSeriesGraphPainter]: the x axis is frequency,
// so the sample-index segment cache doesn't apply — a direct paint is cheap
// at these sizes, and recompute is throttled by [_FftCache].
// ---------------------------------------------------------------------------

/// dB floor for individual bin values (kills -inf at exact zeros).
const double _kFftFloorDb = -220;

/// Fixed bottom of the FFT Y axis (dBFS in amplitude mode, dBFS/√Hz in
/// density mode) — see the axis-range comment in [_FftCache._compute].
const double _kFftAxisFloorDb = -160;
const double _kFftAxisFloorDbAsd = -200;

/// A computed spectrum, ready to draw.
final class _FftResult {
  const _FftResult({
    required this.n,
    required this.binHz,
    required this.fsHz,
    required this.channels,
    required this.loDb,
    required this.hiDb,
    required this.peakChannel,
    required this.peakBin,
    required this.peakDb,
  });

  /// Transform length, Hz per bin, and the sample rate.
  final int n;
  final double binHz;
  final double fsHz;

  /// Per plotted channel: hardware index + dB bins (length n/2 + 1).
  final List<({int channel, Float64List dbBins})> channels;

  /// Display range: [loDb] fixed per mode, [hiDb] snapped above the peak.
  final double loDb;
  final double hiDb;

  /// Loudest non-DC bin across all channels (the marker).
  final int peakChannel;
  final int peakBin;
  final double peakDb;
}

/// What the FFT pane has to show: a spectrum, or the reason it can't
/// compute one right now (short window, gap, no channels).
sealed class _FftOutcome {
  const _FftOutcome();
}

final class _FftEmpty extends _FftOutcome {
  const _FftEmpty(this.message);

  final String message;
}

final class _FftOk extends _FftOutcome {
  const _FftOk(this.result);

  final _FftResult result;
}

/// Memoized spectrum. The result is a function of the pane parameters, the
/// data identity, the plot window, and — while streaming — wall time
/// quantized to 100 ms (capping recompute at 10 Hz with no timers). The
/// window enters the key directly when parked; when following the live edge
/// the window is a pure function of the clock, so the clock covers it.
class _FftCache {
  Object? _key;
  _FftOutcome? _outcome;

  /// Twiddle/window tables per transform length (expensive to build).
  final Map<int, Radix2Fft> _tables = {};

  /// Drop the memo when the data source is swapped (a static source may
  /// alias another's key — both report dataGeneration 0).
  void clear() => _key = null;

  _FftOutcome resolve({
    required GraphDataSource data,
    required GraphController ctrl,
    required DisplayUnit unit,
    required List<_ConvertedChannel> channels,
    required int? requestedN,
    required bool asd,
  }) {
    final total = data.totalSamples;
    final last = data.lastDataAt;
    final clock = last == null ? 0 : last.millisecondsSinceEpoch ~/ 100;
    final (winStart, winEnd) = ctrl.effectiveRange(total, data.oldestSample);
    final key = (
      data.dataGeneration,
      data.calibrationVersion,
      data.tareVersion,
      unit,
      asd,
      requestedN,
      [for (final c in channels) c.channel].join(','),
      ctrl.isLive ? 'live' : (winStart, winEnd),
      clock,
      total,
    );
    final cached = _outcome;
    if (key == _key && cached != null) return cached;

    _key = key;
    return _outcome = _compute(
      data,
      channels,
      requestedN: requestedN,
      asd: asd,
      winStart: winStart,
      winEnd: winEnd,
    );
  }

  _FftOutcome _compute(
    GraphDataSource data,
    List<_ConvertedChannel> channels, {
    required int? requestedN,
    required bool asd,
    required int winStart,
    required int winEnd,
  }) {
    if (channels.isEmpty) return const _FftEmpty('No channels selected');
    if (winEnd <= winStart) return const _FftEmpty('No data in the window');
    // Only samples still in the retained buffer can feed the transform.
    final oldest = data.oldestSample;
    final usable = winEnd - (winStart > oldest ? winStart : oldest);
    final n = fftWindowN(usable, requestedN);
    if (n == null) {
      return const _FftEmpty('Window too short — zoom out or pick a smaller N');
    }
    final start = winEnd - n;
    if (data.gaps.rangesIn(start, winEnd).isNotEmpty) {
      return const _FftEmpty('Gap in the FFT window — pan elsewhere');
    }

    final fs = data.sampleRate.toDouble();
    final fft = _tables.putIfAbsent(n, () => Radix2Fft(n));
    // √Hz mode normalizes by the window's noise bandwidth (Hann ENBW): the
    // N-invariant noise density. Tones read inflated — honest.
    final norm = asd ? 1.0 / math.sqrt(fs / n * Radix2Fft.hannEnbwBins) : 1.0;
    final samples = Float64List(n);
    final spectra = <({int channel, Float64List dbBins})>[];
    double maxDb = double.negativeInfinity;
    int peakChannel = channels.first.channel, peakBin = 1;
    double peakDb = double.negativeInfinity;
    for (final bound in channels) {
      final net = bound.netMap;
      for (int i = 0; i < n; i++) {
        samples[i] = net(data.rawAt(bound.channel, start + i).toDouble());
      }
      final spec = fft.amplitudeSpectrum(samples);
      // Reference: the channel's full-scale span (2^23 counts for hardware,
      // the summed rail span for blends, 1.0 for ratios) expressed in the
      // display unit — "dBFS" reads as the instrument's input span in every
      // unit, tare-independent.
      final fsDisplay = bound.diffMap(bound.fullScaleRaw);
      final db = Float64List(spec.length);
      for (int k = 0; k < spec.length; k++) {
        final a = spec[k] * norm / fsDisplay;
        final v = a <= 0
            ? _kFftFloorDb
            : math.max(20 * math.log(a) / math.ln10, _kFftFloorDb);
        db[k] = v;
        if (k == 0) continue; // DC excluded from stats (mean-removed)
        if (v > maxDb) maxDb = v;
        if (v > peakDb) {
          peakDb = v;
          peakBin = k;
          peakChannel = bound.channel;
        }
      }
      spectra.add((channel: bound.channel, dbBins: db));
    }
    // Fixed floor per mode (data-independent → the axis can't jitter);
    // deeper bins clamp onto the bottom frame edge at draw time, reading
    // as a saturated range rather than disappearing. The √Hz floor sits
    // lower: the density normalization lifts the noise floor by
    // 10·log10(1/(binHz·ENBW)), which turns negative (floor sinks) at
    // small N — ~20 dB down at N = kFftMinN against a fast stream.
    final lo = asd ? _kFftAxisFloorDbAsd : _kFftAxisFloorDb;
    // Top snaps up to the 10 dB grid above the loudest bin, so it steps
    // only when the peak itself moves a detent. +2 dB of headroom, and a
    // drawable range even for an all-silence transform (maxDb at the
    // -220 bin floor).
    final hi = math.max((((maxDb + 2) / 10).ceil() * 10).toDouble(), lo + 10);
    return _FftOk(
      _FftResult(
        n: n,
        binHz: fs / n,
        fsHz: fs,
        channels: spectra,
        loDb: lo,
        hiDb: hi,
        peakChannel: peakChannel,
        peakBin: peakBin,
        peakDb: peakDb,
      ),
    );
  }
}

class _FftPanePainter extends CustomPainter {
  _FftPanePainter(
    this._cache, {
    required this.data,
    required this.ctrl,
    required this.channels,
    required this.requestedN,
    required this.asd,
    required this.logX,
    required this.colorScheme,
    required this.labels,
    required this.unit,
  }) : super(repaint: Listenable.merge([data.repaint, ctrl]));

  static const double _topSpace = 18;
  static const double _bottomSpace = 16;

  final _FftCache _cache;
  final GraphDataSource data;
  final GraphController ctrl;

  /// The workspace's channel selection (the stats-table toggles),
  /// unit-bound — same list the dF/dt pane plots.
  final List<_ConvertedChannel> channels;
  final int? requestedN;
  final bool asd;

  /// X scale. Display-only: the transform result ([_FftCache]) is shared
  /// between both, so it stays out of the cache key.
  final bool logX;
  final ColorScheme colorScheme;
  final _LabelCache labels;
  final DisplayUnit unit;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(_kGraphLeftSpace, _topSpace);
    final graphSz = Size(
      size.width - _kGraphLeftSpace - kGraphRightSpace,
      size.height - _topSpace - _bottomSpace,
    );
    if (graphSz.width <= 0 || graphSz.height <= 0) return;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, graphSz.width, graphSz.height),
      Paint()
        ..color = colorScheme.primary.withAlpha(150)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    switch (_cache.resolve(
      data: data,
      ctrl: ctrl,
      unit: unit,
      channels: channels,
      requestedN: requestedN,
      asd: asd,
    )) {
      case _FftEmpty(:final message):
        _drawCenteredMessage(canvas, graphSz, message);
      case _FftOk(:final result):
        _paintSpectrum(canvas, graphSz, result);
    }
  }

  void _drawCenteredMessage(Canvas canvas, Size graphSz, String message) {
    final par = labels.prepare(
      message,
      color: colorScheme.onSurface.withAlpha(150),
      maxWidth: graphSz.width,
    );
    canvas.drawParagraph(
      par,
      Offset(
        (graphSz.width - par.longestLine).clamp(0.0, graphSz.width) / 2,
        graphSz.height / 2 - par.height / 2,
      ),
    );
  }

  void _paintSpectrum(Canvas canvas, Size graphSz, _FftResult r) {
    final textColor = colorScheme.onSurface.withAlpha(150);

    // The unit tag rides the band above the frame (the Y axis's unit lives
    // at the right). The transform summary goes inside the frame's
    // top-left: its 13 pt line box is taller than the band, so up there it
    // straddled the frame border. The peak readout drops a row below it
    // (see below), so no two texts share a row by construction.
    final modeTag = labels.prepare(asd ? 'dBFS/√Hz' : 'dBFS', color: textColor);
    final infoTag = labels.prepare(
      'Hann · N=${r.n} · '
      'Δf=${r.binHz.toStringAsFixed(r.binHz < 1 ? 2 : 1)} Hz · '
      '${formatWindowSpan(r.n / r.fsHz)}',
      color: textColor,
      maxWidth: graphSz.width - 8,
    );
    canvas.drawParagraph(
      modeTag,
      Offset(graphSz.width - modeTag.longestLine - 4, 2 - _topSpace),
    );
    canvas.drawParagraph(infoTag, const Offset(4, 2));

    double valueToY(double v) =>
        graphSz.height - (v - r.loDb) * graphSz.height / (r.hiDb - r.loDb);

    final fMax = r.fsHz / 2;
    // Log: the axis spans exactly the computed spectrum's non-DC bins
    // (bin 1 .. Nyquist) — no fmin knob, nothing to clamp.
    final logMin = math.log(r.binHz), logMax = math.log(fMax);
    double freqToX(double f) => logX
        ? (math.log(f) - logMin) / (logMax - logMin) * graphSz.width
        : f / fMax * graphSz.width;

    final gridMinor = Path();
    final gridMajor = Path();
    _drawAxis(
      canvas,
      gridMinor,
      gridMajor,
      graphSz,
      orientation: _AxisOrientation.y,
      windowStart: r.loDb,
      windowEnd: r.hiDb,
      step: 10.0,
      stepCeil: _decadeStepCeil,
      labelFor: (tick) => tick.toStringAsFixed(0),
      posOf: valueToY,
      showLabels: true,
      labels: labels,
      textColor: colorScheme.onSurface,
    );
    // Frequency grid. Linear: ~5 nice ticks, edges skipped (the frame
    // already marks them). Log: labeled decades with unlabeled 2–9 minors;
    // the span is log10(N/2) ≈ 1.8–4.5 decades, so both always fit.
    // Labeled lines are majors, unlabeled minors — like [_drawAxis]'s tiers.
    if (logX) {
      final dMin = logMin / math.ln10, dMax = logMax / math.ln10;
      for (int d = dMin.floor(); d <= dMax.ceil(); d++) {
        final decade = math.pow(10, d).toDouble();
        if (decade >= r.binHz && decade <= fMax) {
          final x = freqToX(decade);
          gridMajor.moveTo(x, 0);
          gridMajor.lineTo(x, graphSz.height);
          final par = labels.prepare(
            decade.toStringAsFixed(d < 0 ? -d : 0),
            color: colorScheme.onSurface,
          );
          canvas.drawParagraph(
            par,
            Offset(x - par.longestLine / 2, graphSz.height + 2),
          );
        }
        for (int m = 2; m <= 9; m++) {
          final f = decade * m;
          if (f < r.binHz || f > fMax) continue;
          final x = freqToX(f);
          gridMinor.moveTo(x, 0);
          gridMinor.lineTo(x, graphSz.height);
        }
      }
    } else {
      final step = _decadeStepCeil(fMax / 5);
      final freqDecimals = step >= 1 ? 0 : 1;
      for (double f = step; f < fMax; f += step) {
        final x = freqToX(f);
        gridMajor.moveTo(x, 0);
        gridMajor.lineTo(x, graphSz.height);
        final par = labels.prepare(
          f.toStringAsFixed(freqDecimals),
          color: colorScheme.onSurface,
        );
        canvas.drawParagraph(
          par,
          Offset(x - par.longestLine / 2, graphSz.height + 2),
        );
      }
    }
    // Same pen tiers as the force graph: labeled lines (majors) get more
    // ink than unlabeled minors.
    final gridMinorPen = Paint()
      ..color = colorScheme.onSurface.withAlpha(45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.2;
    final gridMajorPen = Paint()
      ..color = colorScheme.onSurface.withAlpha(80)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.4;
    canvas.drawPath(gridMinor, gridMinorPen);
    canvas.drawPath(gridMajor, gridMajorPen);

    // Spectra. Bins below the display floor pile onto the bottom edge —
    // a saturated range, not lost data.
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final spec in r.channels) {
      final color = getChannelColor(spec.channel);
      final batcher = VertexBatcher(
        preserveFloats: 2,
        drawThreshold: 2,
        onFlush: (view) {
          pen.color = color;
          canvas.drawRawPoints(ui.PointMode.polygon, view, pen);
        },
      );
      final bins = spec.dbBins;
      // log(0) undefined: the DC bin has no log home and stays linear-only.
      for (int k = logX ? 1 : 0; k < bins.length; k++) {
        batcher.add(freqToX(k * r.binHz), valueToY(math.max(bins[k], r.loDb)));
        if (batcher.wouldOverflow(2)) batcher.flush();
      }
      batcher.flush();
    }

    // Peak marker + readout.
    final peakFreq = r.peakBin * r.binHz;
    final px = freqToX(peakFreq);
    canvas.drawLine(
      Offset(px, 0),
      Offset(px, graphSz.height),
      Paint()
        ..color = getChannelColor(r.peakChannel).withAlpha(160)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
    final peakLabel = labels.prepare(
      '${peakFreq.toStringAsFixed(peakFreq < 10 ? 2 : 1)} Hz · '
      '${r.peakDb.toStringAsFixed(0)} dB',
      color: colorScheme.onSurface,
    );
    // Second text row, below the info tag; kept inside the plot on either
    // side of the marker.
    final lx = px + 4 + peakLabel.longestLine > graphSz.width
        ? px - 4 - peakLabel.longestLine
        : px + 4;
    canvas.drawParagraph(peakLabel, Offset(lx, 20));
  }

  @override
  bool shouldRepaint(covariant _FftPanePainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Force plate pane (2D)
// ---------------------------------------------------------------------------

/// Newest valid plate sample of a rendered (sub)range of the trail, in the
/// pane's two axis coordinates. One per rendered range; [ForcePlateCache]
/// stores it per baked bucket so the newest-dot marker outlives texture
/// caching without a window rescan.
typedef _PlateMarker = ({double x, double y});

/// The two-axis position view: the pane's X/Y channels plotted as a plate
/// coordinate over a trail of every window sample (dots cached write-once
/// by [ForcePlateCache], live head/tail vector-drawn — see that file). The
/// painter owns no channel math: the axis channels are bound derived
/// channels, undefined samples (an unloaded plate) carry no dot.
class _ForcePlatePainter extends CustomPainter {
  _ForcePlatePainter(
    this._data,
    this._ctrl, {
    required this.xChannel,
    required this.yChannel,
    required this.errChannel,
    required this.corners,
    required this.unit,
    required this.cache,
    required this.colorScheme,
    required this.dpr,
    required this.labels,
    required this.bakePump,
    required this.ellipses,
    required this.trails,
  }) : super(repaint: Listenable.merge([_data.repaint, _ctrl, bakePump]));

  final GraphDataSource _data;
  final GraphController _ctrl;

  /// The pane's axis channels (unit-bound).
  final _ConvertedChannel xChannel;
  final _ConvertedChannel yChannel;

  /// The plate's saddle/error channel, drawn as the live bar in the right
  /// gutter (see [_drawErrBar]).
  final _ConvertedChannel errChannel;

  /// Corner labels: (member channel, x-sign, y-sign) from the axis
  /// channels' weight signs.
  final List<(int channel, double sx, double sy)> corners;

  /// Cache stamp ingredient: the channels bind the unit at bind time.
  final DisplayUnit unit;

  /// Persistent, owned by [_GraphWorkspaceState] (like [_forceCache]); no
  /// recreation rules — a config change clears inside the cache.
  final ForcePlateCache<_PlateMarker> cache;

  /// CoP-cloud confidence ellipses (see [PlateEllipseOverlay]), drawn over
  /// the trail.
  final List<PlateEllipseOverlay> ellipses;

  /// CoP polylines of individual passes (see [PlateTrailOverlay]).
  final List<PlateTrailOverlay> trails;

  final ColorScheme colorScheme;
  final double dpr;
  final _LabelCache labels;

  /// Drives the rolling bucket bakes (static sources never fire repaint on
  /// their own — see [_TimeSeriesGraphPainter.bakePump]).
  final BakePump bakePump;

  /// Plot coordinate extent: plate edges at ±1, ±1.3 leaves margin for
  /// off-plate points (clamped to ±1.25) and corner labels.
  static const double _extent = 1.3;

  /// Trail dot radius and flat alpha. Uniform alpha is what makes the
  /// bucket textures write-once: a window-dependent fade would tie the dots
  /// to the window and defeat caching.
  static const double _kDotRadius = 1.4;
  static const int _kDotAlpha = 160;

  @override
  void paint(Canvas canvas, Size size) {
    const double topSpace = 2;
    const double bottomSpace = 4;
    canvas.translate(_kGraphLeftSpace, topSpace);
    final plotW = size.width - _kGraphLeftSpace - kGraphRightSpace;
    final plotH = size.height - topSpace - bottomSpace;
    if (plotW <= 0 || plotH <= 0) return;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, plotW, plotH),
      Paint()
        ..color = colorScheme.primary.withAlpha(150)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    // The plate is square; center it in the plot's width.
    final side = math.max(0.0, math.min(plotW - 8, plotH));
    final left = (plotW - side) / 2;
    Offset toPx(double x, double y) => Offset(
      left + (x + _extent) / (2 * _extent) * side,
      // Canvas y grows down; plate +y is up.
      (_extent - y) / (2 * _extent) * side,
    );

    // Plate outline + corner channel labels.
    canvas.drawRect(
      Rect.fromPoints(toPx(-1, 1), toPx(1, -1)),
      Paint()
        ..color = colorScheme.onSurface.withAlpha(120)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    for (final (ch, sx, sy) in corners) {
      final par = labels.prepare(rigSlotTitle(ch), color: getChannelColor(ch));
      final p = toPx(sx * 0.88, sy * 0.85);
      canvas.drawParagraph(
        par,
        Offset(p.dx - par.longestLine / 2, p.dy - par.height / 2),
      );
    }

    // Trail over the window: one dot per sample, cached by [cache]. The
    // painter owns nothing per-dot here — both the bake canvas and the
    // live vector draws funnel through [_renderDots] at plate-local origin.
    final total = _data.totalSamples;
    _PlateMarker? marker;
    if (total > 0) {
      final (vs, ve) = _ctrl.effectiveRange(total, _data.oldestSample);
      if (side > 0) {
        // Plate-local pixel of a clamped position (toPx without the left offset).
        Offset pointFor(double x, double y) => Offset(
          (x + _extent) / (2 * _extent) * side,
          (_extent - y) / (2 * _extent) * side,
        );
        final dotPaint = Paint()
          ..color = colorScheme.primary.withAlpha(_kDotAlpha);
        canvas.save();
        canvas.translate(left, 0);
        final trail = cache.paint(canvas, (
          generation: _data.dataGeneration,
          configKey: [
            unit,
            _data.calibrationVersion,
            _data.tareVersion,
            xChannel.channel,
            yChannel.channel,
            side,
            dpr,
          ],
          side: side,
          dpr: dpr,
          viewStart: vs,
          viewEnd: ve,
          oldestSample: _data.oldestSample,
          totalSamples: total,
          render: (c, start, end) =>
              _renderDots(c, start, end, pointFor, dotPaint),
        ));
        canvas.restore();
        marker = trail.marker;
        if (trail.workRemains) bakePump.schedule();
      }
      _drawErrBar(canvas, plotW, plotH, vs, ve);
    }

    // Pass polylines (gait lines), under the ellipses/head marker.
    for (final t in trails) {
      if (t.points.length < 2) continue;
      final path = Path()
        ..moveTo(
          toPx(t.points.first.$1, t.points.first.$2).dx,
          toPx(t.points.first.$1, t.points.first.$2).dy,
        );
      for (int i = 1; i < t.points.length; i++) {
        final p = toPx(t.points[i].$1, t.points[i].$2);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = t.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }

    // Confidence ellipses over the trail, under the head marker.
    for (final e in ellipses) {
      final c = toPx(e.cx, e.cy);
      final scale = side / (2 * _extent);
      canvas.save();
      canvas.translate(c.dx, c.dy);
      // Plate coordinates are y-up; the canvas is y-down, so the rotation
      // sign flips.
      canvas.rotate(-e.angleRad);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: 2 * e.semiA * scale,
          height: 2 * e.semiB * scale,
        ),
        Paint()
          ..color = e.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      canvas.restore();
    }

    if (marker != null) {
      final center = toPx(
        marker.x.clamp(-1.25, 1.25),
        marker.y.clamp(-1.25, 1.25),
      );
      canvas.drawCircle(center, 3.5, Paint()..color = colorScheme.primary);
      canvas.drawCircle(
        center,
        3.5,
        Paint()
          ..color = colorScheme.surface
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    } else if (total > 0) {
      final par = labels.prepare(
        'no positive load in the window',
        color: colorScheme.onSurface.withAlpha(150),
        maxWidth: plotW,
      );
      canvas.drawParagraph(
        par,
        Offset(
          (plotW - par.longestLine).clamp(0.0, plotW) / 2,
          plotH / 2 - par.height / 2,
        ),
      );
    }
  }

  /// Fixed full-scale of the err bar: the plate's saddle residual as a
  /// fraction of its total load. Sized from practice: up to ±0.26 observed
  /// on the dev plates, so 0.3 keeps it on scale with headroom. Fixed (not
  /// autoscaled) so a quiet plate reads quiet.
  static const double _kErrScale = 0.3;

  /// The error channel's instantaneous value as a vertical bar in the right
  /// gutter: newest defined sample of the window (the same instant as the
  /// trail's end marker), centered at zero, clamped to ±[_kErrScale].
  void _drawErrBar(
    Canvas canvas,
    double plotW,
    double plotH,
    int viewStart,
    int viewEnd,
  ) {
    final channel = errChannel;
    final net = channel.netMap;
    // The scan is capped so an unloaded plate (undefined ratio samples)
    // can't turn it into a full-window sweep per frame.
    double? err;
    final scanFrom = math.max(viewStart, viewEnd - 4000);
    for (int j = viewEnd - 1; j >= scanFrom; j--) {
      final raw = _data.rawValueAt(channel.channel, j);
      if (!raw.isNaN) {
        err = net(raw);
        break;
      }
    }

    final dim = colorScheme.onSurface.withAlpha(150);
    final tag = labels.prepare('Err', color: dim);
    final valuePar = labels.prepare(
      err == null ? '—' : err.toStringAsFixed(3),
      color: colorScheme.onSurface,
    );
    final trackTop = tag.height + 4;
    final trackBottom = plotH - valuePar.height - 4;
    if (trackBottom <= trackTop) return;

    final cx = plotW + kGraphRightSpace / 2;
    const halfW = 6.0;
    final halfH = (trackBottom - trackTop) / 2;
    final midY = trackTop + halfH;

    final outline = Paint()
      ..color = colorScheme.onSurface.withAlpha(120)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(
      Rect.fromLTRB(cx - halfW, trackTop, cx + halfW, trackBottom),
      outline,
    );
    // Zero tick.
    canvas.drawLine(
      Offset(cx - halfW - 2, midY),
      Offset(cx + halfW + 2, midY),
      outline,
    );
    if (err != null) {
      final frac = (err / _kErrScale).clamp(-1.0, 1.0);
      canvas.drawRect(
        Rect.fromPoints(
          Offset(cx - halfW, midY),
          Offset(cx + halfW, midY - frac * halfH),
        ),
        Paint()..color = channel.color.withAlpha(160),
      );
    }
    canvas.drawParagraph(tag, Offset(cx - tag.longestLine / 2, 0));
    canvas.drawParagraph(
      valuePar,
      Offset(cx - valuePar.longestLine / 2, plotH - valuePar.height),
    );
  }

  /// The trail loop, shared by bucket bakes and the live vector head/tail:
  /// one dot per sample at the pane's two channel values; undefined samples
  /// (gaps, no positive load) skipped. Returns the newest valid sample of
  /// [start, end) (see [_PlateMarker]).
  _PlateMarker? _renderDots(
    Canvas canvas,
    int start,
    int end,
    Offset Function(double x, double y) pointFor,
    Paint dotPaint,
  ) {
    _PlateMarker? last;
    for (int j = start; j < end; j++) {
      final x = xChannel.netMap(_data.rawValueAt(xChannel.channel, j));
      final y = yChannel.netMap(_data.rawValueAt(yChannel.channel, j));
      if (x.isNaN || y.isNaN) continue;
      canvas.drawCircle(
        pointFor(x.clamp(-1.25, 1.25), y.clamp(-1.25, 1.25)),
        _kDotRadius,
        dotPaint,
      );
      last = (x: x, y: y);
    }
    return last;
  }

  @override
  bool shouldRepaint(covariant _ForcePlatePainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _formatTickLabel(double value, String unitSymbol, int decimals) =>
    '${_formatTickValue(value, decimals)} $unitSymbol';

/// Tick label digits, fixed at [decimals] (derived from the tick step by
/// [DisplayUnit.axisDecimalsFor]): every label on one axis shares a width,
/// and ticks always resolve their step.
String _formatTickValue(double value, int decimals) =>
    value.toStringAsFixed(decimals);
