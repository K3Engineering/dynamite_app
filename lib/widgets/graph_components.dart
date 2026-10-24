import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meta/meta.dart';

import '../models/bucket_series.dart';
import '../models/channel_limits.dart';
import '../models/device_profile.dart';
import '../models/display_unit.dart';
import '../models/gap_list.dart';
import '../models/graph_data_source.dart';
import '../models/load_cell.dart';
import '../utils/nice_step.dart';
import 'channel_palette.dart';
import 'graph/block_reduction_cache.dart';
import 'graph/graph_controller.dart';
import 'graph/segmented_cache.dart';

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
@visibleForTesting
int blockSizeFor(double viewSamples, double graphW) {
  assert(
    graphW > 0,
    'graphW must be positive, got $graphW',
  ); // callers only paint into non-degenerate plot areas
  // floor => >= 1 sample/block, so the polyline's vertex count tracks the
  // pixel width. The remainder (viewSamples % blockSize) lands in the short
  // final block.
  final size = math.max(1, (viewSamples / graphW).floor());
  if (size < 2 * kBucketSize) return size;
  // Bucket-align big blocks: block indices are anchored at absolute sample 0,
  // so a whole-multiple blockSize makes every COMPLETE block span whole
  // buckets. Bucket reduction then equals the exact reduction, and a complete
  // block's min/max no longer depends on how full the newest bucket was when
  // it was first reduced (the immutable-reduction contract of
  // [BlockReductionCache]). Rounding UP keeps the vertex bound.
  return ((size + kBucketSize - 1) ~/ kBucketSize) * kBucketSize;
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

/// One active channel bound to the view's display unit. Its display maps are
/// materialized non-null here, so painters never re-ask availability.
@immutable
final class _ConvertedChannel {
  const _ConvertedChannel._({
    required this.channel,
    required this.tare,
    required this.netMap,
    required this.meanFromMvV,
    required this.diffMap,
    required this.sensitivityCountsPerMvV,
    required this.loadCell,
  });

  /// Null when [unit] does not convert on the channel (a force unit with no
  /// load cell assigned).
  static _ConvertedChannel? of(
    GraphDataSource data,
    int channel,
    DisplayUnit unit,
  ) {
    final converter = data.converterFor(channel);
    final net = converter.netMap(unit);
    if (net == null) return null;
    final diff = converter.diffMap(unit);
    // diff is null exactly when net is (see ChannelConverter); a divergence
    // is a broken calibration-model invariant, not an unavailable unit.
    assert(diff != null, 'net converts but diff does not (CH$channel, $unit)');
    if (diff == null) return null;
    return _ConvertedChannel._(
      channel: channel,
      tare: converter.tare,
      netMap: net,
      meanFromMvV: converter.netMeanMvVMap(unit),
      diffMap: diff,
      sensitivityCountsPerMvV:
          converter.calibration.board?.sensitivityCountsPerMvV,
      loadCell: converter.calibration.loadCell,
    );
  }

  final int channel;

  /// Tare offset in counts; null = untared ([ChannelConverter.tare]).
  final double? tare;

  /// Raw -> display value, net of tare ([ChannelConverter.netMap]).
  final double Function(double raw) netMap;

  /// mV/V mean -> display mean, exact for converted units
  /// ([ChannelConverter.netMeanMvVMap]); null for raw and unavailable
  /// channels, where bucket means keep using the raw-sum approximation.
  final double Function(double meanMvV)? meanFromMvV;

  /// Raw diff -> display diff, terminal-slope based ([ChannelConverter.diffMap]).
  final double Function(double rawDiff) diffMap;

  /// Board sensitivity, used to size the force graph gutter's capacity zone.
  /// Null only for raw on a nominal-less board (raw bypasses the board map and
  /// still converts).
  final double? sensitivityCountsPerMvV;

  /// Null when no cell is assigned.
  final LoadCellProfile? loadCell;
}

// ---------------------------------------------------------------------------
// Minimap
// ---------------------------------------------------------------------------

class _Minimap extends StatefulWidget {
  final GraphDataSource dataSource;
  final DisplayUnit unit;
  final GraphController graphCtrl;

  /// Channels to plot, bound to [unit] in the workspace (see
  /// [_ConvertedChannel]).
  final List<_ConvertedChannel> channels;

  const _Minimap({
    required this.dataSource,
    required this.unit,
    required this.graphCtrl,
    required this.channels,
  });

  @override
  State<_Minimap> createState() => _MinimapState();
}

class _MinimapState extends State<_Minimap> {
  final SegmentedGraphCache _cache = SegmentedGraphCache();
  final BlockReductionCache _reductionCache = BlockReductionCache();
  final BakePump _bakePump = BakePump();

  @override
  void dispose() {
    _bakePump.dispose();
    _cache.dispose();
    super.dispose();
  }

  /// The minimap's window in samples: `(totalSamples, (mapStart, mapSpan))`,
  /// or null when there is nothing to map (no data, or a plot too narrow to
  /// divide by). Tap and drag both read it, so the two gestures cannot
  /// disagree about the map's scale.
  (int, (int, int))? _mapWindow(double graphWidth) {
    final totalSamples = widget.dataSource.totalSamples;
    if (totalSamples == 0 || graphWidth <= 0) return null;
    final mapSpan = widget.graphCtrl.defaultLiveSpan(
      totalSamples,
      widget.dataSource.oldestSample,
    );
    return (totalSamples, (totalSamples - mapSpan, mapSpan));
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
      mapStart + (frac * mapSpan).round(),
      totalSamples,
      widget.dataSource.oldestSample,
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
                    colorScheme,
                    dpr,
                    _cache,
                    _reductionCache,
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
  final ColorScheme _colorScheme;
  final double _dpr;
  final SegmentedGraphCache _cache;

  /// Completed-block reduction memo (see [BlockReductionCache]), owned by
  /// the host [State] next to [_cache] (_dispose-free: pure Dart maps).
  final BlockReductionCache _reductionCache;

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
    this._colorScheme,
    this._dpr,
    this._cache,
    this._reductionCache,
    this._bakePump,
  ) : super(repaint: Listenable.merge([_data.repaint, _ctrl, _bakePump]));

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
    final mapSpan = _ctrl.defaultLiveSpan(totalSamples, oldestSample);
    final mapStart = totalSamples - mapSpan;

    // Bucket-folded extremes over the retained window, like the force
    // painter. The lifetime [GraphDataSource.channelExtremes] never shrink,
    // so after a ring wrap they would keep scaling Y by evicted samples the
    // minimap can no longer draw.
    final ext = _foldNetExtremes(_data, _channels, mapStart, totalSamples);
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
      viewStart: mapStart.toDouble(),
      viewEnd: (mapStart + mapSpan).toDouble(),
      data: _data,
      color: _colorScheme.error,
    );

    // Shared envelope data layer (see [_paintEnvelopeDataLayer]).
    final workRemains = _paintEnvelopeDataLayer(
      canvas,
      cache: _cache,
      reductionCache: _reductionCache,
      data: _data,
      channels: _channels,
      tares: [for (final bound in _channels) bound.tare],
      unit: _unit,
      gw: gw,
      gh: gh,
      dpr: _dpr,
      viewStart: mapStart.toDouble(),
      viewSpan: mapSpan.toDouble(),
      yMin: yMin,
      yMax: yMax,
      firstUsableSample: oldestSample,
      seriesFor: (bound) => _taredEnvelopeSeries(_data, bound),
      avgStrokeWidth: 1.0,
      avgAlpha: 180,
    );
    if (workRemains) _bakePump.schedule();

    final (viewStart, viewEnd) = _ctrl.effectiveRange(
      totalSamples,
      oldestSample,
    );
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
  final bool showDerivative;

  /// Whether the source is the live feed (vs a loaded session); gates the
  /// LIVE button and the semantics wording. Unrelated to
  /// [GraphController.isLive] (viewport mode) and
  /// [GraphController.lockedLiveSpan] (rolling animation).
  final bool isLiveSource;

  const GraphWorkspace({
    super.key,
    required this.data,
    required this.ctrl,
    required this.unit,
    required this.activeChannels,
    this.showDerivative = false,
    this.isLiveSource = true,
  });

  @override
  State<GraphWorkspace> createState() => _GraphWorkspaceState();
}

class _GraphWorkspaceState extends State<GraphWorkspace>
    with SingleTickerProviderStateMixin {
  final SegmentedGraphCache _forceCache = SegmentedGraphCache();
  final BlockReductionCache _forceReductionCache = BlockReductionCache();
  final SegmentedGraphCache _derivCache = SegmentedGraphCache();
  final BlockReductionCache _derivReductionCache = BlockReductionCache();
  final BakePump _bakePump = BakePump();

  /// One label cache per painter: [AxisLabelCache] treats a paint as a pass,
  /// and two painters sharing a cache would make the first painter's labels
  /// evictible during the second one's pass.
  final AxisLabelCache _forceLabels = AxisLabelCache();
  final AxisLabelCache _derivLabels = AxisLabelCache();

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
    _derivCache.dispose();
    _forceLabels.dispose();
    _derivLabels.dispose();
    super.dispose();
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
        channels: [for (final bound in convertedChannels) bound.channel],
        unit: unit,
        hasDerivative: widget.showDerivative,
      ),
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(
                flex: widget.showDerivative ? 6 : 10,
                child: _GraphPane(
                  data: widget.data,
                  ctrl: widget.ctrl,
                  painter: _ForceGraphPainter(
                    widget.data,
                    widget.ctrl,
                    unit: unit,
                    channels: convertedChannels,
                    showXLabels: !widget.showDerivative,
                    vsync: _vsync,
                    cache: _forceCache,
                    reductionCache: _forceReductionCache,
                    colorScheme: colorScheme,
                    dpr: dpr,
                    labels: _forceLabels,
                    bakePump: _bakePump,
                  ),
                ),
              ),
              if (widget.showDerivative)
                Expanded(
                  flex: 4,
                  child: _GraphPane(
                    data: widget.data,
                    ctrl: widget.ctrl,
                    painter: _DerivativeGraphPainter(
                      widget.data,
                      widget.ctrl,
                      unit: unit,
                      channels: convertedChannels,
                      vsync: _vsync,
                      cache: _derivCache,
                      reductionCache: _derivReductionCache,
                      colorScheme: colorScheme,
                      dpr: dpr,
                      labels: _derivLabels,
                      bakePump: _bakePump,
                    ),
                  ),
                ),
              _Minimap(
                dataSource: widget.data,
                unit: unit,
                graphCtrl: widget.ctrl,
                channels: convertedChannels,
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
  });

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
        final (start, end) = ctrl.effectiveRange(
          data.totalSamples,
          data.oldestSample,
        );
        return Positioned(
          right: 64,
          top: 8,
          child: FilledButton.icon(
            onPressed: () => ctrl.goLive(
              span: end - start,
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

  /// A zoom segment; [label] is the hover tooltip and the button's
  /// accessible name.
  ///
  /// The name goes inside the button because [Tooltip]'s own semantics node
  /// sits above the button: a separate focus stop with no tap action. A label
  /// inside merges into the button's node.
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
        child: Semantics(label: label, child: Icon(icon)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
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
                  // No icon to carry the name: the readout is the whole
                  // child, so its value joins this label in the button's node.
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
/// per packet. The stats table speaks live readings.
String _graphSemanticsLabel({
  required bool live,
  required List<int> channels,
  required DisplayUnit unit,
  required bool hasDerivative,
}) {
  final kind = live ? 'Live' : 'Recorded';
  final chs = channels.isEmpty
      ? 'No channels plotted'
      : 'Channels: ${channels.map(rigSlotTitle).join(', ')}';
  final deriv = hasDerivative ? '. Rate-of-change graph below' : '';
  return '$kind force graph. $chs. Unit: ${unit.symbol}$deriv.';
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

/// Clock-nice step ladder, as rungs of seconds/minutes/hours, used by
/// [timeStepCeil]. 30 s and friends keep m:ss labels meaningful; a 1/2/5
/// decade of "100 s" would print 1:40.
const _kClockRungs = [1, 2, 5, 10, 20, 30, 60];

/// Smallest clock-nice step >= [target] seconds: 1/2/5 decades below one
/// second ([niceStepCeil]), then [_kClockRungs] of seconds, minutes, hours, ...
@visibleForTesting
double timeStepCeil(double target) {
  if (target < 1) return niceStepCeil(target);
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
@visibleForTesting
String formatAxisTick(double sec, int decimals) {
  if (sec < 0) return '-${formatAxisTick(-sec, decimals)}';
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
/// label's measured width (see [_fitTimeLines]).
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
  // Flat data (or the 0,0 no-data derivative fold) has dataMax == dataMin:
  // widen it to a unit window. Anything non-finite is a broken conversion
  // upstream, so let it fail in the tick math rather than drawing a plausible
  // axis for corrupt state.
  final double lo = dataMin;
  final double max = dataMax <= lo ? lo + 1.0 : dataMax;

  // 1/2/5 tick delta sized so ticks land at least [_kMinYTickPx] apart.
  final tickDelta = niceStepCeil((max - lo) * _kMinYTickPx / plotHeight);

  // Snap yMin and yMax to tick boundaries
  final yMin = (lo / tickDelta).floor() * tickDelta;
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
@visibleForTesting
int majorPeriod(double step, double Function(double target) stepCeil) {
  final superStep = stepCeil(5 * step);
  final period = (superStep / step).round();
  assert(
    (superStep - period * step).abs() < step * 1e-6,
    'superStep $superStep is not a multiple of step $step',
  );
  return period;
}

/// Fractional digits for [formatAxisTick] at [step]: enough to resolve the step,
/// capped at 3 (ms).
int _timeDecimals(double step) =>
    step >= 1 ? 0 : (-(math.log(step) / math.ln10).floor()).clamp(1, 3);

/// One enumerated axis tick: its value on the absolute k*step grid, pixel
/// position, prepared label paragraph, and major flag.
class _AxisTick {
  const _AxisTick(this.value, this.pos, this.par, this.major);
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
  const _AxisLines(this.ticks, this.minorPos, {required this.clipLabels});
  final List<_AxisTick> ticks;
  final Iterable<double> minorPos;
  final bool clipLabels;
}

/// One labeled tick of an axis grid before any label paragraph exists: grid
/// value, major flag, pixel position. The pure half of [_enumAxisLines].
typedef AxisTick = ({double value, double pos, bool major});

/// The pure tick grid at [step] over [windowStart]..[windowEnd] widened by
/// [enumSlack], lazily ([_fitTimeLines] re-enumerates at candidate steps).
/// Nothing here prepares a label, so tests can pin it without a cache.
///
/// Labeled ticks live on the absolute grid k * step, so they (and the majors)
/// hold still while the window slides; indexing by k rather than accumulating
/// keeps the major test exact and makes the k == 0 tick literally 0.0.
///
/// [enumSlack] extends the population past both window edges; X passes one
/// tick plus the live edge's worst lead jitter ([_kLiveEdgeLeadMs]), so a
/// rolling window micro-oscillating across an edge tick slides it in and out
/// instead of toggling it per frame. Y snaps its range to tick boundaries and
/// passes 0. The inclusive end (step * 0.01) leaves room for fp noise, so a
/// line exactly on the snapped or slacked edge draws.
Iterable<AxisTick> axisTicks(
  double windowStart,
  double windowEnd, {
  required double step,
  required double Function(double target) stepCeil,
  required double enumSlack,
  required double Function(double value) posOf,
}) sync* {
  final period = majorPeriod(step, stepCeil);
  final lo = windowStart - enumSlack;
  final hi = windowEnd + enumSlack + step * 0.01;
  // The 1e-9 nudge keeps a tick exactly at the window edge from dropping out
  // to fp error: yMin is itself snapped to a tick boundary (see
  // [_computeYRange]), and (yMin / step).ceil() can land one step high.
  for (int k = (lo / step - 1e-9).ceil(); k * step <= hi; k++) {
    yield (value: k * step, pos: posOf(k * step), major: k % period == 0);
  }
}

/// The pixel positions of the half-step minor lines over [axisTicks]' window,
/// lazily (see [axisTicks]). Minor lines live on the ODD half-step grid,
/// indexed by j so the overlap test is exact: even multiples of minorStep are
/// the labeled ticks, so starting at the first odd j and stepping by 2 skips
/// them.
Iterable<double> axisMinorTicks(
  double windowStart,
  double windowEnd, {
  required double step,
  required double enumSlack,
  required double Function(double value) posOf,
}) sync* {
  final minorStep = step / 2;
  final hi = windowEnd + enumSlack + step * 0.01;
  final firstMinor = ((windowStart - enumSlack) / minorStep - 1e-9).ceil();
  for (
    int j = firstMinor.isEven ? firstMinor + 1 : firstMinor;
    j * minorStep <= hi;
    j += 2
  ) {
    yield posOf(j * minorStep);
  }
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
        case _AxisOrientation.x:
          canvas.drawParagraph(
            t.par,
            Offset(t.pos - t.par.longestLine / 2, graphSz.height + 2),
          );
        case _AxisOrientation.y:
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
  final (avg: avg, env: env) = _envelopeBatchers(
    canvas,
    avgColor: color.withAlpha(avgAlpha),
    avgStrokeWidth: avgStrokeWidth,
    envColor: color.withAlpha(envAlpha),
  );

  // Buckets pay off (and stay accurate) once a block spans >= 2 buckets.
  final buckets = series.buckets;
  final bool useBuckets = blockSize >= 2 * buckets.bucketSize;

  // Anchored to absolute sample 0, not viewStart, so caching stays
  // scroll-invariant.
  final int startBlock = (math.max(viewStart, firstUsableSample) / blockSize)
      .floor();
  final int endBlock = (renderEnd / blockSize).ceil();

  for (int k = startBlock; k < endBlock; k++) {
    final int sStart = k * blockSize;
    final int sEnd = math.min(
      sStart + blockSize,
      renderEnd,
    ); // last block may be short

    final int drawStart = math.max(sStart, firstUsableSample);
    if (drawStart >= sEnd) continue;
    // Short only at the trailing block or a firstUsableSample clip.
    assert(
      sEnd - drawStart >= 1 && sEnd - drawStart <= blockSize,
      'block [$drawStart, $sEnd) has bad size for blockSize $blockSize',
    );

    // A block is immutable -- reducible once, cacheable forever -- only
    // when it is complete (fully written at the data edge) and unclipped
    // by the retention edge (a [drawStart] clip is re-derived every frame
    // as the edge advances). See [BlockReductionCache].
    final bool complete = drawStart == sStart && sEnd - sStart == blockSize;
    final BlockReduction r = reductionCache.resolve(
      channel: channelIndex,
      blockIndex: k,
      complete: complete,
      reduce: () => useBuckets
          ? reduceBlockBuckets(series, drawStart, sEnd)
          : reduceBlockExact(series.sampleAt, drawStart, sEnd),
    );

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

/// Paint the segment-cached envelope data layer for the window
/// [viewStart, viewStart + viewSpan) mapped to x in [0, gw): the pipeline
/// shared by the force graph, derivative graph, and minimap.
///
/// [seriesFor] returns the per-channel rendering recipe. Cache keying: the
/// display [unit], calibration version, and [tares] are destructive (never
/// blitted once stale); the channel list is the remap key (stale segments keep
/// blitting as ghosts while swept); a data-generation change clears the cache.
/// See the staleness model on [SegmentedGraphCache]. [reductionCache] memos
/// completed-block reductions under the same identity (generation +
/// destructive key + block grid; see [BlockReductionCache]), so the
/// live-edge gap draws and (re)bakes reduce each block once instead of
/// every frame.
///
/// Returns true when bake work remains; the owner should schedule another
/// frame.
@useResult
bool _paintEnvelopeDataLayer(
  Canvas canvas, {
  required SegmentedGraphCache cache,
  required BlockReductionCache reductionCache,
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
  // segment keys: keying on it would churn every packet after a ring wrap
  // and force full rebakes of unchanged segments. Instead clip the whole
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
  // Share the destructive-key list with the reduction cache's upkeep (the
  // identity model matches one-to-one, so both flip on the same change).
  final destructiveKey = <Object?>[unit, data.calibrationVersion, ...tares];
  reductionCache.prepare(
    generation: data.dataGeneration,
    destructiveKey: destructiveKey,
    blockSize: blockSize,
    viewBlockStart: (viewStart / blockSize).floor(),
    viewBlockEnd: ((viewStart + viewSpan) / blockSize).ceil(),
  );
  final workRemains = cache.paint(canvas, (
    config: (
      generation: data.dataGeneration,
      destructiveKey: destructiveKey,
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
    ),
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
  Path? path;
  for (final (gs, ge) in gaps.rangesIn(start, end)) {
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
    path.addRect(
      Rect.fromLTRB(
        (gs - start) * pxPerSample,
        -_kUnbounded,
        (ge - start) * pxPerSample,
        _kUnbounded,
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

  /// Channels to plot, bound to [_unit] in the workspace (see
  /// [_ConvertedChannel]).
  final List<_ConvertedChannel> _channels;
  final SegmentedGraphCache cache;

  /// Completed-block reduction memo, owned and disposed by the host [State]
  /// next to [cache] (see [BlockReductionCache]).
  final BlockReductionCache reductionCache;
  final ColorScheme colorScheme;

  /// Device pixel ratio used when rasterizing segment textures.
  final double dpr;

  /// Axis-label paragraph cache, owned (and disposed) by the host [State].
  final AxisLabelCache labels;

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
    required this.reductionCache,
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
    labels.beginPass();
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
    double xToPx(double sec) =>
        (sec - startSec) * sampleRate * graphSz.width / viewSamples;
    double xSlack(double step) => step + _kLiveEdgeLeadMs / 1000.0;
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
      orientation: _AxisOrientation.x,
      lines: xLines,
      showLabels: showXLabels,
    );
    _drawAxis(
      canvas,
      gridMinor,
      gridMajor,
      graphSz,
      orientation: _AxisOrientation.y,
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

    // -- Data lines (segment-cached envelope) --
    final workRemains = _paintEnvelopeDataLayer(
      canvas,
      cache: cache,
      reductionCache: reductionCache,
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
    required super.reductionCache,
    required super.colorScheme,
    required super.dpr,
    required super.labels,
    required super.bakePump,
  });

  @override
  double get topSpace => 4;

  @override
  List<double?> cacheKeyTares() =>
      _channels.map((bound) => bound.tare).toList();

  @override
  EnvelopeSeries series(_ConvertedChannel channel) =>
      _taredEnvelopeSeries(_data, channel);

  @override
  YAxisRange? computeYRange(
    double viewStart,
    double viewEnd,
    double plotHeight,
  ) {
    // [windowedRawExtremes] folds full buckets and scans only the partial
    // head/tail: O(window / bucketSize). No minimum-range floor; flat data
    // hits the degeneracy guard in [_computeYRange].
    // No plotted channel has data in the window: paint blank.
    final ext = _foldNetExtremes(
      _data,
      _channels,
      viewStart.floor(),
      viewEnd.ceil(),
    );
    if (ext == null) return null;

    return _computeYRange(ext.$1, ext.$2, _unit, plotHeight);
  }

  /// Limit bars in the right gutter: one column per channel, a rail zone from
  /// the ADC rail to the plot edge and (with a load cell) a capacity zone from
  /// 100% capacity to the rail. Projected through the unit converter net of
  /// tare (see [ChannelConverter.diffMap]); clamping to the plot rect
  /// collapses off-view and empty zones.
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
      final cell = bound.loadCell;
      final span = bound.sensitivityCountsPerMvV;
      // Net display value at 100% cell capacity; null without a cell or the
      // board sensitivity to size it.
      final cellNet = cell != null && span != null
          ? bound.diffMap(cell.sensitivityMvV * span)
          : null;
      final left = graphSz.width + colW * bound.channel;

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
  _DerivativeGraphPainter(
    super.data,
    super.ctrl, {
    required super.unit,
    required super.channels,
    required super.vsync,
    required super.cache,
    required super.reductionCache,
    required super.colorScheme,
    required super.dpr,
    required super.labels,
    required super.bakePump,
  });

  @override
  double get topSpace => 2;

  @override
  int get firstSampleOffset => 1; // first difference needs sample j-1

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
  YAxisRange? computeYRange(
    double viewStart,
    double viewEnd,
    double plotHeight,
  ) {
    // [windowedExtremes] folds full buckets and scans only the partial
    // head/tail: O(window / bucketSize).
    final (startI, endI) = _data.clampToRetained(
      viewStart.floor(),
      viewEnd.ceil(),
    );
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
    // No channel data: degenerate 0..1 axis via [_computeYRange]'s guard.
    return _computeYRange(dMin ?? 0.0, dMax ?? 0.0, _unit, plotHeight);
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
