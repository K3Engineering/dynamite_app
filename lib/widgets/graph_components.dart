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
import '../models/load_cell.dart';
import '../utils/nice_step.dart';
import 'channel_palette.dart';
import 'graph/axis_math.dart';
import 'graph/block_reduction_cache.dart';
import 'graph/envelope_renderer.dart';
import 'graph/graph_controller.dart';
import 'graph/tile_cache.dart';
import 'graph/surface_cache.dart';

export 'graph/axis_math.dart';
export 'graph/envelope_renderer.dart';
export 'graph/graph_controller.dart';
export 'graph/tile_cache.dart';

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

/// Extent for clip rects that must cover any plot area plus its stroke/pad
/// overdraw (the only bounded thing there is the other axis).
const double _kUnbounded = 1e9;

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
  ctrl.zoom(
    zoomFactor,
    focalFrac,
    totalSamples,
    data.oldestSample,
    generation: data.dataGeneration,
  );
}

// ---------------------------------------------------------------------------
// Unit-bound channels
// ---------------------------------------------------------------------------

/// One active channel bound to the view's display unit, spanning the whole
/// channel id space (hardware 0..3, derived 4.. — see `derived_channel.dart`).
/// Its display maps are materialized non-null here, so painters never re-ask
/// availability.
@immutable
final class _ConvertedChannel {
  const new _({
    required this.channel,
    required this.cacheTares,
    required this.netMap,
    required this.meanFromMvV,
    required this.diffMap,
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
      // Only hardware channels have an mV/V space at all (see
      // [ChannelConverter.netMeanMvVMap]); derived rings store their own
      // quantized units, so bucket means use the raw-sum path there.
      meanFromMvV: hw == null
          ? null
          : data.converterFor(hw).netMeanMvVMap(unit),
      diffMap: diff,
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

  /// Ring -> display value, net of tare; raw-space channels: raw counts ->
  /// display value ([SeriesConverter.netMap]).
  final double Function(double raw) netMap;

  /// mV/V mean -> display mean, exact for converted units
  /// ([ChannelConverter.netMeanMvVMap]); null for raw, derived, and
  /// unavailable channels, where bucket means keep using the raw-sum
  /// approximation.
  final double Function(double meanMvV)? meanFromMvV;

  /// Raw diff -> display diff, terminal-slope based ([ChannelConverter.diffMap]).
  final double Function(double rawDiff) diffMap;

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
}

// ---------------------------------------------------------------------------
// Minimap
// ---------------------------------------------------------------------------

class _Minimap extends StatefulWidget {
  final GraphDataSource dataSource;
  final DisplayUnit unit;
  final GraphController graphCtrl;

  /// The shared window snapshot all chart surfaces paint from (see
  /// [_GraphGeometry]); both the map window and the painter's window-change
  /// repaints come from it, so the map cannot disagree with the main graphs.
  final ValueListenable<_GraphGeometry> geometry;

  /// Channels to plot, bound to [unit] in the workspace (see
  /// [_ConvertedChannel]).
  final List<_ConvertedChannel> channels;

  const new({
    required this.dataSource,
    required this.unit,
    required this.graphCtrl,
    required this.geometry,
    required this.channels,
  });

  @override
  State<_Minimap> createState() => _MinimapState();
}

class _MinimapState extends State<_Minimap> {
  final GraphSurfaceCache _cache = GraphSurfaceCache();
  final BakePump _bakePump = BakePump();

  @override
  void didUpdateWidget(_Minimap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataSource != widget.dataSource) {
      _cache.clear();
    }
  }

  @override
  void dispose() {
    _bakePump.dispose();
    _cache.dispose();
    super.dispose();
  }

  /// The minimap's window: `(totalSamples, (mapStart, mapSpan))` in
  /// fractional samples, or null when there is nothing to map (no data, or a
  /// plot too narrow to divide by). The window is the same snapshot the
  /// painter draws from (see [_GraphGeometry]), so a gesture maps onto
  /// exactly the scale on screen.
  (int, (double, double))? _mapWindow(double graphWidth) {
    final totalSamples = widget.dataSource.totalSamples;
    if (totalSamples == 0 || graphWidth <= 0) return null;
    final geo = widget.geometry.value;
    return (totalSamples, (geo.mapStart, geo.mapSpan));
  }

  void _onMinimapTap(TapDownDetails d, double graphWidth) {
    final window = _mapWindow(graphWidth);
    if (window == null) return;
    final (totalSamples, (mapStart, mapSpan)) = window;
    final frac = ((d.localPosition.dx - _kGraphLeftSpace) / graphWidth).clamp(
      0.0,
      1.0,
    );
    widget.graphCtrl.centerOn(
      (mapStart + frac * mapSpan).round(),
      totalSamples,
      widget.dataSource.oldestSample,
      generation: widget.dataSource.dataGeneration,
    );
  }

  void _onMinimapDrag(DragUpdateDetails d, double graphWidth) {
    final window = _mapWindow(graphWidth);
    if (window == null) return;
    final (totalSamples, (_, mapSpan)) = window;
    widget.graphCtrl.pan(
      (d.delta.dx * mapSpan / graphWidth).round(),
      totalSamples,
      widget.dataSource.oldestSample,
      generation: widget.dataSource.dataGeneration,
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
              behavior: .opaque,
              onPointerSignal: (e) => _handleGraphPointerScroll(
                e,
                widget.dataSource,
                widget.graphCtrl,
                graphWidth,
              ),
              child: GestureDetector(
                behavior: .opaque,
                onTapDown: (d) => _onMinimapTap(d, graphWidth),
                onHorizontalDragUpdate: (d) => _onMinimapDrag(d, graphWidth),
                child: CustomPaint(
                  foregroundPainter: _MinimapPainter(
                    widget.dataSource,
                    widget.unit,
                    widget.geometry,
                    widget.channels,
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

  /// The shared window snapshot (see [_GraphGeometry]): the map window and
  /// the viewport box both come from it, and it drives repaints for window
  /// changes; [_data].repaint covers the rest (new data, tare, calibration).
  final ValueListenable<_GraphGeometry> _geo;
  final List<_ConvertedChannel> _channels;
  final ColorScheme _colorScheme;
  final double _dpr;
  final GraphSurfaceCache _cache;

  /// Drives the rolling tile bakes: a repaint listenable for this painter
  /// and the scheduler for extra frames when bake work remains (rolling
  /// bootstrap / staleness passes must complete even for static sources
  /// whose [GraphDataSource.repaint] never fires).
  final BakePump _bakePump;

  new(
    this._data,
    this._unit,
    this._geo,
    this._channels,
    this._colorScheme,
    this._dpr,
    this._cache,
    this._bakePump,
  ) : super(repaint: Listenable.merge([_data.repaint, _geo, _bakePump]));

  @override
  void paint(Canvas canvas, Size size) {
    const double vPad = 2;

    canvas.translate(_kGraphLeftSpace, vPad);
    final gw = _graphPlotWidth(size.width);
    final gh = size.height - vPad * 2;

    if (gw <= 0 || gh <= 0) return;

    final bgPaint = Paint()..color = _colorScheme.surface;
    canvas.drawRect(Rect.fromLTWH(0, 0, gw, gh), bgPaint);

    final totalSamples = _data.totalSamples;
    if (totalSamples == 0) return;

    final oldestSample = _data.oldestSample;
    final geo = _geo.value;
    final mapStart = geo.mapStart;
    final mapSpan = geo.mapSpan;

    // Bucket-folded extremes over the retained window, like the force
    // painter. The lifetime [GraphDataSource.channelExtremes] never shrink,
    // so after a ring wrap they would keep scaling Y by evicted samples the
    // minimap can no longer draw.
    final (foldStart, foldEnd) = foldBlockSpan(
      mapStart,
      mapStart + mapSpan,
      blockSizeFor(mapSpan, gw),
    );
    final ext = _foldNetExtremes(_data, _channels, foldStart, foldEnd);
    if (ext == null) return;
    // Zero is a display-space anchor, so include it even when the data does
    // not cross it.
    final yMin = math.min(ext.$1, 0.0);
    var yMax = math.max(ext.$2, 0.0);
    // Non-degenerate on flat data (the mapping divides by the span).
    if (yMax <= yMin) yMax = yMin + 1;

    // Hatching sits behind the data lines, like the main graphs.
    _drawMissingDataHatching(
      canvas,
      Size(gw, gh),
      viewStart: mapStart,
      viewEnd: mapStart + mapSpan,
      data: _data,
      color: _colorScheme.error,
    );

    // Shared envelope data layer (see [_paintEnvelopeDataLayer]).
    final workRemains = _paintEnvelopeDataLayer(
      canvas,
      cache: _cache,
      data: _data,
      channels: _channels,
      tares: [for (final bound in _channels) ...bound.cacheTares],
      unit: _unit,
      gw: gw,
      gh: gh,
      dpr: _dpr,
      viewStart: mapStart,
      viewSpan: mapSpan,
      yMin: yMin,
      yMax: yMax,
      firstUsableSample: oldestSample,
      seriesFor: (bound) => _taredEnvelopeSeries(_data, bound),
      avgStrokeWidth: 1.0,
      avgAlpha: 180,
    );
    if (workRemains) _bakePump.schedule();

    // The viewport box is the main graphs' window from the same snapshot,
    // so it sits exactly where the graphs' window sits. A parked window
    // stays pinned in absolute time as eviction passes it (see
    // [GraphController.effectiveRange]), so the box slides off the left;
    // clamp it to the map or its border would draw into the Y-label gutter.
    // Fully off it collapses to a line on the left edge -- the main graph
    // shows the "beyond history" state.
    final viewStart = geo.viewStart;
    final viewEnd = geo.viewEnd;
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

/// Pan/pinch handling for one plot surface. The px<->sample mapping reads
/// the controller's INTEGER windows ([GraphController.effectiveRange]), not
/// the floated paint window ([_GraphGeometry]): right-edge gestures snap to
/// live ([GraphController.zoomTo]), so the only residual mismatch is a
/// rolling view gliding under an in-flight gesture, bounded by the
/// live-edge lead ([_kLiveEdgeCapMs]).
class _InteractiveGraphArea extends StatefulWidget {
  final GraphDataSource data;
  final GraphController ctrl;
  final Widget child;

  const new({required this.data, required this.ctrl, required this.child});

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

    final (s, e) = widget.ctrl.effectiveRange(
      total,
      widget.data.oldestSample,
      generation: widget.data.dataGeneration,
    );
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
        generation: widget.data.dataGeneration,
      );
    } else {
      final dx = details.localFocalPoint.dx - session.focalX;
      final deltaSamples = -(dx * session.span / graphWidth).round();
      widget.ctrl.applyWindow(
        session.startSample + deltaSamples,
        session.span,
        total,
        oldestSample,
        generation: widget.data.dataGeneration,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphWidth = _graphPlotWidth(constraints.maxWidth);
        return Listener(
          behavior: .opaque,
          onPointerSignal: (e) => _handleGraphPointerScroll(
            e,
            widget.data,
            widget.ctrl,
            graphWidth,
          ),
          child: GestureDetector(
            behavior: .opaque,
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

  const new({
    super.key,
    required this.data,
    required this.ctrl,
    required this.unit,
    required this.activeChannels,
    this.analysis = const AnalysisPaneSelection(),
  });

  @override
  State<GraphWorkspace> createState() => _GraphWorkspaceState();
}

class _GraphWorkspaceState extends State<GraphWorkspace>
    with SingleTickerProviderStateMixin {
  final GraphSurfaceCache _forceCache = GraphSurfaceCache();

  /// Cache for the coordinates graph (the unitless channels' split pane —
  /// see [build]); like [_forceCache], it serves one painter kind only.
  final GraphSurfaceCache _coordCache = GraphSurfaceCache();

  /// Cache for the analysis pane's time-series variants (the derivative);
  /// recreated when the pane KIND changes so a previous pane's segments
  /// can't ghost into the new one.
  GraphSurfaceCache? _analysisCache;

  final BakePump _bakePump = BakePump();

  /// One label cache per painter: [AxisLabelCache] treats a paint as a pass,
  /// and two painters sharing a cache would make the first painter's labels
  /// evictible during the second one's pass.
  final AxisLabelCache _forceLabels = AxisLabelCache();
  final AxisLabelCache _coordLabels = AxisLabelCache();
  final AxisLabelCache _analysisLabels = AxisLabelCache();

  /// The one window snapshot every chart surface paints from (see
  /// [_GraphGeometry]); its notifier also drives the painters' repaints for
  /// window changes (data content repaints ride [GraphDataSource.repaint]).
  /// Recomputed once per geometry-relevant change: each vsync tick while
  /// live (see [_syncTicker]), and synchronously when the data source or
  /// controller notifies.
  late final Ticker _ticker;
  late final ValueNotifier<_GraphGeometry> _geometry;

  @override
  void initState() {
    super.initState();
    _geometry = ValueNotifier(_computeGeometry(widget.data, widget.ctrl));
    _ticker = createTicker((_) {
      _updateGeometry();
      _syncTicker(); // a stalled stream stops the ticker from within
    });
    widget.ctrl.addListener(_onGeometrySourceChanged);
    widget.data.repaint.addListener(_onGeometrySourceChanged);
    _syncTicker();
  }

  @override
  void didUpdateWidget(GraphWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ctrl != widget.ctrl || oldWidget.data != widget.data) {
      oldWidget.ctrl.removeListener(_onGeometrySourceChanged);
      oldWidget.data.repaint.removeListener(_onGeometrySourceChanged);
      widget.ctrl.addListener(_onGeometrySourceChanged);
      widget.data.repaint.addListener(_onGeometrySourceChanged);
      // Static sources all use generation 0, so identity is the reset signal.
      if (oldWidget.data != widget.data) {
        _forceCache.clear();
        _coordCache.clear();
        _analysisCache?.clear();
        if (oldWidget.ctrl == widget.ctrl) {
          widget.ctrl.reset();
        }
      }
      _onGeometrySourceChanged();
    }
    if (oldWidget.analysis.kind != widget.analysis.kind) {
      _analysisCache?.dispose();
      _analysisCache = null;
    }
  }

  void _updateGeometry() {
    _geometry.value = _computeGeometry(widget.data, widget.ctrl);
  }

  void _onGeometrySourceChanged() {
    _updateGeometry();
    _syncTicker();
  }

  /// Runs only while a live viewport animates on a fresh stream; the next
  /// packet's repaint restarts it after a stall. Parked windows don't tick:
  /// nothing on screen moves between packets there, so the packet's own
  /// repaint suffices. (A static source's [lastDataAt] is null, so it never
  /// passes the freshness test.)
  void _syncTicker() {
    final DateTime? last = widget.data.lastDataAt;
    final bool fresh =
        last != null &&
        DateTime.now().difference(last).inMilliseconds < _kTickerStallMs;
    final bool shouldTick = widget.ctrl.isLive && fresh;
    // isActive, not isTicking: start() throws on isActive, and a started
    // ticker is active before its first frame, so isTicking can't guard a
    // double start() (web delivers batches as in-frame microtasks).
    if (shouldTick == _ticker.isActive) return;
    shouldTick ? _ticker.start() : _ticker.stop();
  }

  @override
  void dispose() {
    widget.ctrl.removeListener(_onGeometrySourceChanged);
    widget.data.repaint.removeListener(_onGeometrySourceChanged);
    _ticker.dispose();
    _geometry.dispose();
    _bakePump.dispose();
    _forceCache.dispose();
    _coordCache.dispose();
    _analysisCache?.dispose();
    _forceLabels.dispose();
    _coordLabels.dispose();
    _analysisLabels.dispose();
    super.dispose();
  }

  /// The analysis pane slot's content: a pane widget for the current
  /// selection, or null when collapsed. [bound] is the workspace's
  /// active-channel list, unit-bound.
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

    switch (sel.kind) {
      case null:
        return null;
      case AnalysisPaneKind.derivative:
        return _GraphPane(
          data: data,
          ctrl: ctrl,
          painter: _DerivativeGraphPainter(
            data,
            unit: unit,
            channels: bound,
            geometry: _geometry,
            cache: _analysisCache ??= GraphSurfaceCache(),
            colorScheme: colorScheme,
            dpr: dpr,
            labels: _analysisLabels,
            bakePump: _bakePump,
          ),
        );
    }
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
    // pane draws its own, so the graphs suppress theirs while it's up.
    final paneCarriesTime = widget.analysis.kind == AnalysisPaneKind.derivative;
    final forceXLabels = !hasCoords && !paneCarriesTime;

    Widget timeGraph({
      required List<_ConvertedChannel> channels,
      required GraphSurfaceCache cache,
      required AxisLabelCache labels,
      required bool showXLabels,
    }) => _GraphPane(
      data: widget.data,
      ctrl: widget.ctrl,
      painter: _ForceGraphPainter(
        widget.data,
        unit: unit,
        channels: channels,
        showXLabels: showXLabels,
        geometry: _geometry,
        cache: cache,
        colorScheme: colorScheme,
        dpr: dpr,
        labels: labels,
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
        live: widget.ctrl.isLiveSource,
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
                    labels: _forceLabels,
                    showXLabels: !paneCarriesTime,
                  ),
                ),
              if (hasForce)
                Expanded(
                  flex: forceFlex,
                  child: timeGraph(
                    channels: forceChannels,
                    cache: _forceCache,
                    labels: _forceLabels,
                    showXLabels: forceXLabels,
                  ),
                ),
              if (hasCoords)
                Expanded(
                  flex: coordFlex,
                  child: timeGraph(
                    channels: coordChannels,
                    cache: _coordCache,
                    labels: _coordLabels,
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
                geometry: _geometry,
                channels: convertedChannels,
              ),
            ],
          ),
          if (widget.ctrl.isLiveSource)
            _LiveButton(data: widget.data, ctrl: widget.ctrl),
        ],
      ),
    );
  }
}

/// One interactive plot surface (gestures + the painted graph), shared by the
/// force and derivative panes.
class _GraphPane extends StatelessWidget {
  const new({required this.data, required this.ctrl, required this.painter});

  final GraphDataSource data;
  final GraphController ctrl;
  final CustomPainter painter;

  @override
  Widget build(BuildContext context) {
    return _InteractiveGraphArea(
      data: data,
      ctrl: ctrl,
      child: CustomPaint(foregroundPainter: painter, size: Size.infinite),
    );
  }
}

/// Return to the live edge of a live graph.
class _LiveButton extends StatelessWidget {
  const new({required this.data, required this.ctrl});

  final GraphDataSource data;
  final GraphController ctrl;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ctrl, data.repaint]),
      builder: (context, _) {
        if (data.totalSamples == 0) {
          return const SizedBox.shrink();
        }
        final (start, end) = ctrl.effectiveRange(
          data.totalSamples,
          data.oldestSample,
          generation: data.dataGeneration,
        );
        if (ctrl.isLive) {
          return const SizedBox.shrink();
        }
        return Positioned(
          right: 64,
          top: 8,
          child: FilledButton.icon(
            onPressed: () => ctrl.goLive(
              span: end - start,
              totalSamples: data.totalSamples,
              oldestSample: data.oldestSample,
              generation: data.dataGeneration,
            ),
            icon: const Icon(Icons.fast_forward, size: 16),
            label: const Text('LIVE'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: .shrinkWrap,
            ),
          ),
        );
      },
    );
  }
}

/// Zoom controls: a split button group [− | span | +]. The middle tile
/// opens a menu of preset window spans, "All" (the whole retained buffer,
/// auto-expanding on live), and a "Custom…" exact-span dialog. A preset is
/// shown only when the source could EVER hold it (the live ring never spans
/// an hour, a 30 s recording never shows minute presets) and greyed until
/// the current data does — so the menu's shape is constant per mount and
/// rows never move, they only un-grey in place as a live stream grows.
/// Row chrome below the graph (see `GraphViewControls`)
class GraphZoomControls extends StatelessWidget {
  const new({super.key, required this.data, required this.ctrl});

  final GraphDataSource data;
  final GraphController ctrl;

  /// Preset window spans for the middle tile's menu: (seconds, label),
  /// decade steps. "All" and "Custom…" follow in the menu.
  static const _presets = [
    (1, '1 s'),
    (10, '10 s'),
    (60, '1 min'),
    (600, '10 min'),
    (3600, '1 h'),
  ];

  // Split-group shapes, twin of the TARE group in `ActionButtons`: rounded
  // outer corners, small inner corners, tiles separated by a 4px gap.
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
    final (s, e) = ctrl.effectiveRange(
      data.totalSamples,
      data.oldestSample,
      generation: data.dataGeneration,
    );
    _zoomToSpan(((e - s) / factor).round(), s, e);
  }

  /// Set an exact window span in samples. [GraphController.zoomTo] clamps;
  /// passing `defaultLiveSpan` ("All") funnels through `goLive` into the
  /// auto-expanding show-everything view over mature data. Anchoring matches
  /// [_zoomBy].
  void _applySpan(int spanSamples) {
    if (data.totalSamples <= 0) return;
    final (s, e) = ctrl.effectiveRange(
      data.totalSamples,
      data.oldestSample,
      generation: data.dataGeneration,
    );
    _zoomToSpan(spanSamples, s, e);
  }

  void _zoomToSpan(int spanSamples, int baseStart, int baseEnd) {
    ctrl.zoomTo(
      spanSamples,
      ctrl.isLive ? 1.0 : 0.5,
      baseStart: baseStart,
      baseSpan: baseEnd - baseStart,
      anchorLiveEdge: ctrl.isLive,
      totalSamples: data.totalSamples,
      oldestSample: data.oldestSample,
      generation: data.dataGeneration,
    );
  }

  /// Open the exact-span dialog prefilled with the current window. A typed
  /// span beyond the retained data clamps inside [GraphController.zoomTo].
  Future<void> _promptCustomSpan(BuildContext context) async {
    if (data.totalSamples <= 0) return;
    final (start, end) = ctrl.effectiveRange(
      data.totalSamples,
      data.oldestSample,
      generation: data.dataGeneration,
    );
    final seconds = await showDialog<double>(
      context: context,
      builder: (_) =>
          _CustomSpanDialog(initialSec: (end - start) / data.sampleRate),
    );
    if (seconds == null) return;
    _applySpan((seconds * data.sampleRate).round());
  }

  /// A zoom tile; [label] is the hover tooltip and the button's
  /// accessible name.
  ///
  /// The name goes on the icon, not the [Tooltip], because a tooltip lands in
  /// its own semantics node above the button: a separate focus stop with no
  /// tap action. A label inside merges into the button's node.
  Widget _zoomButton({
    required String label,
    required IconData icon,
    required RoundedRectangleBorder shape,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: FilledButton(
        style: FilledButton.styleFrom(
          shape: shape,
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: onPressed,
        child: Icon(icon, semanticLabel: label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: .min,
      children: [
        _zoomButton(
          label: 'Zoom out',
          icon: Icons.zoom_out,
          shape: _splitLeft,
          onPressed: () => _zoomBy(1 / 1.1892), // fourth root of 2
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
                excludeFromSemantics: true,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    shape: _splitMid,
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                  // Unlike [_zoomButton] there's no icon here to name, so the
                  // label wraps the readout and its value joins it.
                  child: Semantics(
                    label: 'Visible time window',
                    child: _SpanReadout(data: data, ctrl: ctrl),
                  ),
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
        _zoomButton(
          label: 'Zoom in',
          icon: Icons.zoom_in,
          shape: _splitRight,
          onPressed: () => _zoomBy(1.1892),
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
  const new({required this.initialSec});

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
        mainAxisSize: .min,
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
  const new({required this.data, required this.ctrl});

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
          generation: data.dataGeneration,
        );
        return Container(
          // Wide enough for hours-folded spans ("1:00:00") in bold tabular
          // figures; replay windows can legitimately exceed an hour.
          width: 68,
          alignment: .center,
          child: Text(
            formatWindowSpan((end - start) / data.sampleRate),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onPrimary,
              fontWeight: .bold,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        );
      },
    );
  }
}

/// Screen-reader summary of the graph: structural only, since values churn
/// per packet. The stats table speaks live readings. [channels] carries
/// display names (rig slots or derived-channel labels): a derived id has no
/// rig slot. [paneSuffix] names the analysis pane below the force graph
/// ('. Rate-of-change graph below'), or is empty when the slot is collapsed.
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
/// second, trimmed decimals below a minute ("12.4 s", "30 s"), then rounded
/// to the second in the axis ticks' hours-folding clock shape ([formatAxisTick]):
/// "2:05", "1:00:30".
@visibleForTesting
String formatWindowSpan(double spanSec) {
  // Roll over on the ROUNDED value: values that print "999.9 ms"→"1000" or
  // "59.95 s"→"60 s" take the next unit up instead of emitting "1000 ms" /
  // "60 s".
  if (spanSec < 0.9995) return '${(spanSec * 1000).round()} ms';
  if (spanSec < 59.95) {
    final oneDecimal = spanSec.toStringAsFixed(1);
    return '${oneDecimal.endsWith('.0') ? oneDecimal.substring(0, oneDecimal.length - 2) : oneDecimal} s';
  }
  return formatAxisTick(spanSec, 0);
}

// ---------------------------------------------------------------------------
// Axis label paragraph cache
// ---------------------------------------------------------------------------

/// Bounded cache of laid-out axis-label paragraphs, one per painter. Owned by
/// a host [State] (painters are recreated on rebuild). One painter paints at
/// most once per frame, so a [beginPass] is a frame for its cache.
///
/// Scrolling x labels make the key space unbounded, so overflow evicts only
/// entries the current pass never asked for, and disposal waits for the next
/// [beginPass]: [_fitTimeLines] and [_drawAxis] read `longestLine` off the
/// paragraphs they just enumerated, so disposing inside a pass would hand
/// them a collected native peer.
@visibleForTesting
class AxisLabelCache {
  static const int _limit = 512;

  final Map<String, ui.Paragraph> _cache = HashMap();

  /// Keys prepared since the last [beginPass]; everything else is evictible.
  final Set<String> _touched = HashSet();

  /// Evicted paragraphs, disposed at the next [beginPass].
  final List<ui.Paragraph> _retired = [];

  /// Start a paint pass: dispose what an earlier pass evicted, then forget
  /// which keys the previous pass touched.
  void beginPass() {
    for (final paragraph in _retired) {
      paragraph.dispose();
    }
    _retired.clear();
    _touched.clear();
  }

  /// The laid-out paragraph for [text] in [color], building and caching it on
  /// first use.
  ui.Paragraph prepare(
    String text, {
    Color color = Colors.black,
    bool bold = false,
  }) {
    final key = '$text|${color.toARGB32()}|$bold';
    _touched.add(key);
    final cached = _cache[key];
    if (cached != null) return cached;
    if (_cache.length >= _limit) {
      // Only entries this pass never asked for: the rest may be read again
      // later in the same paint. A pass that alone exceeds the limit grows
      // past it and is evicted by a later one.
      _cache.removeWhere((k, paragraph) {
        if (_touched.contains(k)) return false;
        _retired.add(paragraph);
        return true;
      });
    }
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
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: 96));
    _cache[key] = paragraph;
    return paragraph;
  }

  void dispose() {
    for (final paragraph in _cache.values) {
      paragraph.dispose();
    }
    _cache.clear();
    _touched.clear();
    for (final paragraph in _retired) {
      paragraph.dispose();
    }
    _retired.clear();
  }
}

/// Minimum spacing between axis ticks (logical px): [Size]-based density
/// instead of a fixed tick count, so wide/tall plots get more labels than a
/// phone without crowding either.
const double _kMinXTickPx = 48;

/// Breathing room demanded between neighboring X labels, on top of each
/// label's measured width (see [_fitTimeLines]).
const double _kLabelGapPx = 8;

// ---------------------------------------------------------------------------
// Shared plot toolkit
// ---------------------------------------------------------------------------

/// Which axis [_drawAxis] renders: the grid-line direction and label
/// placement (X: vertical lines, labels centered below the plot; Y:
/// horizontal lines, labels centered vertically past the right edge).
enum _AxisOrientation { x, y }

/// Fractional digits for [formatAxisTick] at [step]: enough to resolve the step,
/// capped at 3 (ms).
int _timeDecimals(double step) =>
    step >= 1 ? 0 : (-(math.log(step) / math.ln10).floor()).clamp(1, 3);

/// One enumerated axis tick: its value on the absolute k*step grid, pixel
/// position, prepared label paragraph, and major flag.
class _AxisTick {
  const new(this.value, this.pos, this.par, this.major);
  final double value;
  final double pos;
  final ui.Paragraph par;
  final bool major;
}

/// One axis's complete per-paint grid population from [_enumAxisLines]: the
/// labeled ticks plus the pixel positions of the half-step minor lines
/// between them. [clipLabels] records whether enumeration extended past the
/// window edges (enumSlack > 0); [_drawAxis] then clips labels to the label
/// strip so slack labels don't bleed into the plot.
class _AxisLines {
  const new(this.ticks, this.minorPos, {required this.clipLabels});
  final List<_AxisTick> ticks;
  final Iterable<double> minorPos;
  final bool clipLabels;
}

/// [_AxisLines] for one axis at [step]: the pure grid above with a label
/// paragraph prepared for each tick.
_AxisLines _enumAxisLines(
  double windowStart,
  double windowEnd, {
  required double step,
  required double Function(double target) stepCeil,
  required double enumSlack,
  required String Function(double tick) labelFor,
  required double Function(double value) posOf,
  required AxisLabelCache labels,
  required Color textColor,
}) {
  return _AxisLines(
    [
      for (final t in axisTicks(
        windowStart,
        windowEnd,
        step: step,
        stepCeil: stepCeil,
        enumSlack: enumSlack,
        posOf: posOf,
      ))
        _AxisTick(
          t.value,
          t.pos,
          labels.prepare(labelFor(t.value), color: textColor, bold: t.major),
          t.major,
        ),
    ],
    axisMinorTicks(
      windowStart,
      windowEnd,
      step: step,
      enumSlack: enumSlack,
      posOf: posOf,
    ),
    clipLabels: enumSlack > 0,
  );
}

/// The X-axis grid lines ([_AxisLines]) at the smallest clock-nice step for
/// the window [startSec, endSec) across [extent] px: the lowest ladder rung
/// keeping ticks at least [_kMinXTickPx] apart, bumped up the ladder until
/// the labels fit with [_kLabelGapPx] to spare -- folded h:mm:ss and
/// fractional labels are wider than the 48 px floor and would overlap
/// (measured, not estimated; the width depends on which ticks are visible).
///
/// [slackOf] maps a candidate step to [_enumAxisLines]'s enumSlack. The fit
/// check reads only labels strictly inside the window: slack edge ticks draw
/// but don't constrain the spacing.
_AxisLines _fitTimeLines(
  double startSec,
  double endSec,
  double extent, {
  required double Function(double step) slackOf,
  required double Function(double target) stepCeil,
  required String Function(double tick, int decimals) labelFor,
  required double Function(double value) posOf,
  required AxisLabelCache labels,
  required Color textColor,
}) {
  final spanSec = endSec - startSec;
  var step = stepCeil(spanSec * _kMinXTickPx / extent);
  for (;;) {
    final decimals = _timeDecimals(step);
    final lines = _enumAxisLines(
      startSec,
      endSec,
      step: step,
      stepCeil: stepCeil,
      enumSlack: slackOf(step),
      labelFor: (tick) => labelFor(tick, decimals),
      posOf: posOf,
      labels: labels,
      textColor: textColor,
    );
    double maxLabelW = 0;
    for (final t in lines.ticks) {
      if (t.value < startSec || t.value >= endSec) continue;
      if (t.par.longestLine > maxLabelW) maxLabelW = t.par.longestLine;
    }
    if (step * extent / spanSec >= maxLabelW + _kLabelGapPx) return lines;
    step = stepCeil(step * (1 + 1e-9)); // next ladder rung up
  }
}

/// Draw one axis's grid lines and tick labels from [lines], enumerated for
/// the current window (X: seconds since session start, via [_fitTimeLines];
/// Y: display units, via [_enumAxisLines] at [YAxisRange.tickDelta]). Major
/// tick lines go to [gridMajor], everything else to [gridMinor]; the caller
/// paints both paths after both axes are drawn.
void _drawAxis(
  Canvas canvas,
  Path gridMinor,
  Path gridMajor,
  Size graphSz, {
  required _AxisOrientation orientation,
  required _AxisLines lines,
  required bool showLabels,
}) {
  void gridLine(double pos, {required bool major}) {
    final path = major ? gridMajor : gridMinor;
    switch (orientation) {
      case .x:
        path
          ..moveTo(pos, 0)
          ..lineTo(pos, graphSz.height);
      case .y:
        path
          ..moveTo(0, pos)
          ..lineTo(graphSz.width, pos);
    }
  }

  if (showLabels) {
    if (lines.clipLabels) {
      // The label strip's size comes from the drawn labels: font height is
      // fixed, widths vary, so take the max over the enumerated paragraphs.
      double maxLabelH = 0;
      double maxLabelW = 0;
      for (final t in lines.ticks) {
        if (t.par.longestLine > maxLabelW) maxLabelW = t.par.longestLine;
        if (t.par.height > maxLabelH) maxLabelH = t.par.height;
      }
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
    for (final t in lines.ticks) {
      switch (orientation) {
        case .x:
          canvas.drawParagraph(
            t.par,
            Offset(t.pos - t.par.longestLine / 2, graphSz.height + 2),
          );
        case .y:
          canvas.drawParagraph(
            t.par,
            Offset(graphSz.width + 4, t.pos - t.par.height / 2),
          );
      }
    }
    if (lines.clipLabels) canvas.restore();
  }

  for (final t in lines.ticks) {
    gridLine(t.pos, major: t.major);
  }
  for (final pos in lines.minorPos) {
    gridLine(pos, major: false);
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

  final hatchPen = Paint()
    ..color = color.withAlpha(60)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;
  final bgPen = Paint()
    ..color = color.withAlpha(20)
    ..style = PaintingStyle.fill;

  void drawHatchRegion(double xStart, double xEnd) {
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

  for (final (xStart, xEnd) in _gapSpansX(
    gaps,
    sScanStart,
    sScanEnd,
    viewStart,
    graphSz.width / viewSamples,
  )) {
    drawHatchRegion(xStart, xEnd);
  }
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
  meanFromMvV: bound.meanFromMvV,
);

/// Fold [channels]' windowed raw extremes over `[start, end)` into one
/// display range, each channel's bounds through its net map (both mapped
/// bounds feed both ends, so a negative display multiplier can't invert the
/// range). Null when no channel covers a sample. Gap samples hold a previous
/// real value, so they can never extend the range: no exclusion needed.
/// Shared by the force graph's Y range and the minimap.
(double, double)? _foldNetExtremes(
  GraphDataSource data,
  List<_ConvertedChannel> channels,
  int start,
  int end,
) {
  double? lo, hi;
  for (final bound in channels) {
    final ext = data.windowedRawExtremes(bound.channel, start, end);
    if (ext == null) continue;
    for (final v in [bound.netMap(ext.$1), bound.netMap(ext.$2)]) {
      if (lo == null || v < lo) lo = v;
      if (hi == null || v > hi) hi = v;
    }
  }
  // lo and hi are always assigned together; null means no channel folded.
  return lo == null ? null : (lo, hi!);
}

/// Paint the tile-cached envelope data layer for the window
/// [viewStart, viewStart + viewSpan) mapped to x in [0, gw): the pipeline
/// shared by the force graph, derivative graph, and minimap.
///
/// [seriesFor] returns the per-channel rendering recipe. Cache keying: the
/// display [unit], calibration version, and optional tare version are
/// suppressing (never blitted once stale); the channel list is the ghost key
/// (stale tiles keep blitting while swept); generation changes clear the cache.
/// See the staleness model on [TileGraphCache]. [reductionCache] memos
/// completed-block reductions under the same identity (generation +
/// suppress key + block grid; see [BlockReductionCache]), so the
/// live-edge gap draws and (re)bakes reduce each block once instead of
/// every frame.
///
/// Returns true when bake work remains; the owner should schedule another
/// frame.
@useResult
bool _paintEnvelopeDataLayer(
  Canvas canvas, {
  required GraphSurfaceCache cache,
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

  final int blockSize = blockSizeFor(viewSpan, gw);
  final double blockPx = blockSize * gw / viewSpan;

  // The bake render clamps content to firstUsableSample (the ring can't
  // serve evicted samples), but that clamp is deliberately NOT in the
  // tile keys: keying on it would churn every packet after a ring wrap
  // and force full rebakes of unchanged tiles. Instead clip the whole
  // draw (bakes and blits alike) at the retention edge so a stale blit
  // can't show evicted-sample ink a fresh draw would omit. A no-op
  // whenever the window starts at or inside usable data.
  final usableX = (firstUsableSample - viewStart) * gw / viewSpan;
  if (usableX > 0) {
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(usableX, -_kUnbounded, 2 * _kUnbounded, 2 * _kUnbounded),
    );
  }
  // Share the suppress-key list with the reduction cache's upkeep (the
  // identity model matches one-to-one, so both flip on the same change).
  final suppressKey = <Object?>[unit, data.calibrationVersion, ...tares];
  final reductionCache = cache.reductions;
  reductionCache.prepare(
    generation: data.dataGeneration,
    suppressKey: suppressKey,
    blockSize: blockSize,
  );
  final workRemains = cache.tiles.paint(canvas, (
    config: (
      generation: data.dataGeneration,
      suppressKey: suppressKey,
      ghostKey: [for (final bound in channels) bound.channel],
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
      bakeHorizon: math.max(0, totalSamples - joinBlockSlackBlocks * blockSize),
      // One block of overshoot can be many px when zoomed past 1 sample/px.
      hPad: math.max(kTileImagePad, blockPx + 2),
      vPad: kTileImagePad,
    ),
    render: (cCanvas, start, end) {
      // The polyline overshoots the tile end into its join block so the
      // line reaches the seam with the neighbor's slope; that block is
      // reduced over its FULL range so the join vertex matches the
      // neighbor's.
      final int limit = math.min(joinBlockEnd(end, blockSize), totalSamples);

      // Clip data ink out of gap x-ranges (the hatching drawn by the chrome
      // is the only marker there). A baked tile's gap set is frozen even
      // though gaps are NOT append-only: new gaps land at the live edge,
      // past the 2-block bake horizon, and pruneBefore drops gaps only left
      // of the retention edge, which the draw-time clip above hides.
      final clip = _gapClipPath(data.gaps, start, limit, gw / viewSpan);
      if (clip != null) {
        cCanvas.save();
        cCanvas.clipPath(clip);
      }
      for (final bound in channels) {
        drawChannelEnvelope(
          cCanvas,
          color: getChannelColor(bound.channel),
          graphW: gw,
          viewStart: start,
          viewSamples: viewSpan,
          blockSize: blockSize,
          renderEnd: limit,
          firstUsableSample: firstUsableSample,
          channelIndex: bound.channel,
          reductionCache: reductionCache,
          series: seriesFor(bound),
          valueToY: valueToY,
          clipEnvelopeSamples: end,
          avgStrokeWidth: avgStrokeWidth,
          avgAlpha: avgAlpha,
          envAlpha: envAlpha,
        );
      }
      if (clip != null) cCanvas.restore();
    },
  ));
  if (usableX > 0) canvas.restore();
  return workRemains;
}

/// The gap ranges overlapping [start, end) as x-coordinate pairs under
/// x = (s - originSamples) * pxPerSample. The single rasterization of "where
/// the gaps are": the paint-time hatching ([_drawMissingDataHatching]) and
/// the bake-time ink clip ([_gapClipPath]) both map through it, so they
/// cannot disagree about a gap's edges.
List<(double, double)> _gapSpansX(
  GapList gaps,
  int start,
  int end,
  double originSamples,
  double pxPerSample,
) => [
  for (final (gs, ge) in gaps.rangesIn(start, end))
    ((gs - originSamples) * pxPerSample, (ge - originSamples) * pxPerSample),
];

/// Everything-except-gaps clip for [start, end) under x = (s - start) *
/// pxPerSample, or null when no gap overlaps (the common case). One huge rect
/// with even-odd gap holes; ranges are disjoint.
Path? _gapClipPath(GapList gaps, int start, int end, double pxPerSample) {
  if (gaps.isEmpty) return null;
  Path? path;
  for (final (x1, x2) in _gapSpansX(
    gaps,
    start,
    end,
    start.toDouble(),
    pxPerSample,
  )) {
    path ??= Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(
        const Rect.fromLTRB(
          -_kUnbounded,
          -_kUnbounded,
          _kUnbounded,
          _kUnbounded,
        ),
      );
    path.addRect(Rect.fromLTRB(x1, -_kUnbounded, x2, _kUnbounded));
  }
  return path;
}

// ---------------------------------------------------------------------------
// Windowed time-series graph painters (force, derivative)
// ---------------------------------------------------------------------------

/// Blank lead framed past the device's projected live end, in ms of samples
/// (see [GraphDataSource.projectedEndAt] for the projection itself). The
/// projection already sweeps the inter-packet gap at frame cadence, so this
/// covers only its residual: envelope slew between packets (~0.1 ms) plus
/// rate-fit noise. It also sets the minimum visible blank: right after a
/// packet commits, the envelope passes through the fresh observation, and
/// the gap is this lead plus that packet's flight time.
const double _kLiveEdgeLeadMs = 5;

/// How far the edge may run ahead of the newest CONFIRMED sample: the lead
/// plus slack for delivery latency (a 20 ms batch plus a couple of skipped
/// 18.75 ms connection events). Farther out the link is stalling, and the
/// edge freezes there instead of gliding into unbounded extrapolation;
/// catch-up re-tightens the band from below, which is the only freeze.
const double _kLiveEdgeCapMs = _kLiveEdgeLeadMs + 80;

/// Also cap the lead at this fraction of the visible span, so at narrow
/// spans a full cap can't detach the trace end from the plot's right edge.
const double _kLiveEdgeLeadSpanFraction = 0.05;

/// Stop the smooth-scroll ticker once the stream is this stale: past the worst
/// normal inter-packet gap, so it never churns mid-stream.
const int _kTickerStallMs = 100;

/// The rolling live edge's clamp band width in samples for [spanSamples]:
/// [_kLiveEdgeCapMs] of data, limited to [_kLiveEdgeLeadSpanFraction] of the
/// span (see that constant).
double _leadCapSamples(GraphDataSource data, double spanSamples) => math.min(
  _kLiveEdgeCapMs * data.sampleRate / 1000.0,
  _kLiveEdgeLeadSpanFraction * spanSamples,
);

/// The fractional-sample window geometry every chart surface (both graphs,
/// the minimap and its viewport box) paints from for one repaint round: the
/// viewport window plus the minimap's map window, derived from ONE read of
/// the device-clock projection. [_GraphWorkspaceState] recomputes it once
/// per update and hands the value down; painters and gesture handlers read
/// the snapshot instead of calling a window function themselves, so the
/// surfaces agree exactly rather than approximately.
///
/// A record, not a class: structural equality makes the workspace's
/// ValueNotifier fire only when the window numbers actually change (a
/// stalled/clamped edge between packets produces no repaint). Repaints for
/// data changes that leave the window untouched (tare, calibration) come
/// from [GraphDataSource.repaint], merged into the painters separately.
typedef _GraphGeometry = ({
  /// The viewport window the force/derivative graphs draw.
  double viewStart,
  double viewEnd,

  /// The minimap's map window (the retained range, right edge floated).
  double mapStart,
  double mapSpan,
});

/// Derive one update's shared [_GraphGeometry]. Live viewports float their
/// right edge on the device-clock projection ([GraphDataSource.projectedEndAt])
/// plus the display lead, clamped into [totalSamples, totalSamples + cap]:
/// the projection is monotone and cancels per-packet delivery jitter, and
/// both clamp bounds are monotone in totalSamples, so the edge can never
/// rewind. A rolling window floats both edges; live "everything" floats only
/// the right one (the left is retention-pinned); parked windows keep their
/// integer edges. The minimap shows the retained range (floored at
/// [GraphController.minLiveSpan] for a young stream) with its right edge
/// floated on the same projection.
_GraphGeometry _computeGeometry(GraphDataSource data, GraphController ctrl) {
  final int totalInt = data.totalSamples;
  final int oldestInt = data.oldestSample;
  final double total = totalInt.toDouble();

  // The update's single clock read. Null before a live stream's first batch
  // (and forever for static sources): such edges pin to the confirmed end.
  final double? proj = data.projectedEndAt();
  double liveEdge(double spanSamples) {
    if (proj == null) return total;
    return (proj + _kLiveEdgeLeadMs * data.sampleRate / 1000.0).clamp(
      total,
      total + _leadCapSamples(data, spanSamples),
    );
  }

  final (viewStart, viewEnd) = ctrl.effectiveRange(
    totalInt,
    oldestInt,
    generation: data.dataGeneration,
  );
  final double vStart, vEnd;
  switch (ctrl.viewport) {
    case GraphLive(:final span?):
      vEnd = liveEdge(span.toDouble());
      vStart = vEnd - span;
    case GraphLive():
      vStart = viewStart.toDouble();
      vEnd = liveEdge((viewEnd - viewStart).toDouble());
    case GraphWindow() || GraphFull():
      vStart = viewStart.toDouble();
      vEnd = viewEnd.toDouble();
  }

  final double mapEnd = liveEdge(
    ctrl.defaultLiveSpan(totalInt, oldestInt).toDouble(),
  );
  final double mapSpan = math.max(
    mapEnd - oldestInt,
    ctrl.minLiveSpan.toDouble(),
  );
  return (
    viewStart: vStart,
    viewEnd: vEnd,
    mapStart: mapEnd - mapSpan,
    mapSpan: mapSpan,
  );
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
  _GraphGeometry geo, {
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

  // The visible window comes from the shared per-update snapshot (see
  // [_GraphGeometry]) -- the painters never derive their own.
  final viewSamples = geo.viewEnd - geo.viewStart;
  if (viewSamples < minSamples) return null;

  return (
    graphSz: graphSz,
    viewStart: geo.viewStart,
    viewEnd: geo.viewEnd,
    viewSamples: viewSamples,
  );
}

/// Shared engine for the windowed time-series graphs (force, derivative).
///
/// Handles the pipeline common to both: frame setup, Y-range for the visible
/// window, axes/grid, zero baseline, missing-data hatching, and the
/// tile-cached envelope rendering. Subclasses define the series being
/// plotted -- [series] (per-channel [EnvelopeSeries]), [computeYRange],
/// [yTickLabel] -- plus layout tweaks and cache-key extras.
abstract class _TimeSeriesGraphPainter extends CustomPainter {
  final GraphDataSource _data;
  final DisplayUnit _unit;

  /// The shared window snapshot (see [_GraphGeometry]) the visible window
  /// comes from; fires repaints for window changes, while [_data].repaint
  /// covers the rest (new data, tare, calibration).
  final ValueListenable<_GraphGeometry> geometry;

  /// Channels to plot, bound to [_unit] in the workspace (see
  /// [_ConvertedChannel]).
  final List<_ConvertedChannel> _channels;
  final GraphSurfaceCache cache;
  final ColorScheme colorScheme;

  /// Device pixel ratio used when rasterizing tile textures.
  final double dpr;

  /// Axis-label paragraph cache, owned (and disposed) by the host [State].
  final AxisLabelCache labels;

  /// Drives the rolling tile bakes: a repaint listenable for this painter
  /// and the scheduler for extra frames when bake work remains (rolling
  /// bakes must complete even for static sources whose
  /// [GraphDataSource.repaint] never fires).
  final BakePump bakePump;

  new(
    this._data, {
    required this.geometry,
    required this._unit,
    required this._channels,
    required this.cache,
    required this.colorScheme,
    required this.dpr,
    required this.labels,
    required this.bakePump,
  }) : super(repaint: Listenable.merge([_data.repaint, geometry, bakePump]));

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
  /// [graphSz] sizes the block grid and tick density.
  YAxisRange? computeYRange(double viewStart, double viewEnd, Size graphSz);

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
    labels.beginPass();
    final layout = _setupGraphFrame(
      canvas,
      size,
      _data,
      geometry.value,
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

    final yRange = computeYRange(viewStart, viewEnd, graphSz);
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
    double xToPx(double sec) =>
        (sec - startSec) * sampleRate * graphSz.width / viewSamples;
    // Slack past the live edge so edge-adjacent ticks don't toggle per frame;
    // sized to the same capped lead the window's right edge can reach.
    double xSlack(double step) =>
        step + _leadCapSamples(_data, viewSamples) / sampleRate;
    final xLines = _fitTimeLines(
      startSec,
      endSec,
      graphSz.width,
      slackOf: xSlack,
      stepCeil: timeStepCeil,
      labelFor: formatAxisTick,
      posOf: xToPx,
      labels: labels,
      textColor: colorScheme.onSurface,
    );
    _drawAxis(
      canvas,
      gridMinor,
      gridMajor,
      graphSz,
      orientation: .x,
      lines: xLines,
      showLabels: showXLabels,
    );
    _drawAxis(
      canvas,
      gridMinor,
      gridMajor,
      graphSz,
      orientation: .y,
      lines: _enumAxisLines(
        yRange.yMin,
        yRange.yMax,
        step: yRange.tickDelta,
        stepCeil: niceStepCeil,
        enumSlack: 0.0,
        labelFor: (tick) => yTickLabel(tick, yRange),
        posOf: valueToY,
        labels: labels,
        textColor: colorScheme.onSurface,
      ),
      showLabels: true,
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
    // side (see [_enumAxisLines]'s enumSlack; its labels clip to the label
    // strip).
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

    // -- Data lines (tile-cached envelope) --
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

  new(
    super.data, {
    this.showXLabels = true,
    required super.geometry,
    required super.unit,
    required super.channels,
    required super.cache,
    required super.colorScheme,
    required super.dpr,
    required super.labels,
    required super.bakePump,
  });

  @override
  double get topSpace => 4;

  @override
  List<double?> cacheKeyTares() => [
    for (final bound in _channels) ...bound.cacheTares,
  ];

  @override
  EnvelopeSeries series(_ConvertedChannel channel) =>
      _taredEnvelopeSeries(_data, channel);

  @override
  YAxisRange? computeYRange(double viewStart, double viewEnd, Size graphSz) {
    final (foldStart, foldEnd) = foldBlockSpan(
      viewStart,
      viewEnd,
      blockSizeFor(viewEnd - viewStart, graphSz.width),
    );
    // Include every sample the block-aligned renderer can put into a bake.
    final ext = _foldNetExtremes(_data, _channels, foldStart, foldEnd);
    if (ext == null) return null;

    return computeYAxisRange(ext.$1, ext.$2, _unit, graphSz.height);
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

      // The two rail bars meet the plot's top and bottom edges respectively;
      // a zero-height rect (rail off-view) paints nothing.
      final railTop = valueToY(
        bound.netMap(ChannelLimits.clipRawPos.toDouble()),
      ).clamp(0.0, graphSz.height);
      final railBot = valueToY(
        bound.netMap(ChannelLimits.clipRawNeg.toDouble()),
      ).clamp(0.0, graphSz.height);
      canvas.drawRect(Rect.fromLTRB(left, 0, left + colW, railTop), railPaint);
      canvas.drawRect(
        Rect.fromLTRB(left, railBot, left + colW, graphSz.height),
        railPaint,
      );

      if (cellNet == null) continue;
      // Capacity zones fill the gap between each rail bar and 100% capacity.
      final cellTop = valueToY(cellNet).clamp(0.0, graphSz.height);
      final cellBot = valueToY(-cellNet).clamp(0.0, graphSz.height);
      canvas.drawRect(
        Rect.fromLTRB(left, railTop, left + colW, cellTop),
        cellPaint,
      );
      canvas.drawRect(
        Rect.fromLTRB(left, cellBot, left + colW, railBot),
        cellPaint,
      );
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
  new(
    super.data, {
    required super.geometry,
    required super.unit,
    required super.channels,
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

  @override
  YAxisRange? computeYRange(double viewStart, double viewEnd, Size graphSz) {
    final (foldStart, foldEnd) = foldBlockSpan(
      viewStart,
      viewEnd,
      blockSizeFor(viewEnd - viewStart, graphSz.width),
    );
    final (startI, endI) = _data.clampToRetained(foldStart, foldEnd);
    // The first difference at index 0 has no predecessor.
    final from = math.max(startI, _data.oldestSample + firstSampleOffset);

    // Each channel folds via the bucket fast path through its own diff map
    // (monotone, so both bounds fold safely). The gap-aware variant keeps
    // synthetic gap-edge zeros out of the axis range (see
    // [windowedDiffExtremes]).
    double? dMin, dMax;
    for (final bound in _channels) {
      final ext = windowedDiffExtremes(
        _data.diffBucketsFor(bound.channel),
        from,
        endI,
        _rawDiffAt(bound.channel),
        _data.gaps,
      );
      if (ext == null) continue;
      final display = _diffDisplayFor(bound);
      for (final d in [display(ext.$1), display(ext.$2)]) {
        if (dMin == null || d < dMin) dMin = d;
        if (dMax == null || d > dMax) dMax = d;
      }
    }
    // No channel data: degenerate 0..1 axis via [computeYAxisRange]'s guard.
    return computeYAxisRange(dMin ?? 0.0, dMax ?? 0.0, _unit, graphSz.height);
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
// Helpers
// ---------------------------------------------------------------------------

String _formatTickLabel(double value, String unitSymbol, int decimals) =>
    '${_formatTickValue(value, decimals)} $unitSymbol';

/// Tick label digits, fixed at [decimals] (derived from the tick step by
/// [DisplayUnit.axisDecimalsFor]): every label on one axis shares a width,
/// and ticks always resolve their step.
String _formatTickValue(double value, int decimals) =>
    value.toStringAsFixed(decimals);
