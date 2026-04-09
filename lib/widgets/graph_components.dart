import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:collection';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/force_unit.dart';

// ---------------------------------------------------------------------------
// Shared Graph Data Source
// ---------------------------------------------------------------------------

/// Data interface required by the shared graph components (main graph, minimap, etc).
/// This allows the components to render either live DataHub data or static SessionData.
abstract class GraphDataSource extends ChangeNotifier {
  /// Total number of samples currently available.
  int get sampleCount;

  /// The sample rate of the data (Hz).
  int get sampleRate;

  /// The calibration slope used to convert raw counts to kgf.
  double get calibrationSlope;

  /// Returns the raw data array for a given channel index.
  List<int> getChannelData(int channelIndex);

  /// Returns the minimum raw value for a given channel index.
  double getChannelMin(int channelIndex);

  /// Returns the maximum raw value for a given channel index.
  double getChannelMax(int channelIndex);

  /// Returns the tare offset for a given channel index (0 for pre-tared data).
  double getChannelTare(int channelIndex);
}

// ---------------------------------------------------------------------------
// Graph viewport controller (shared between force graph, derivative, minimap)
// ---------------------------------------------------------------------------

class GraphController extends ChangeNotifier {
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
  /// from the right edge. Null means "show all data from _viewStart".
  int? _liveSpan;

  /// Snap to live mode -- follow the right edge at current zoom level.
  void goLive() {
    if (_viewEnd != null) {
      _liveSpan = _viewEnd! - _viewStart;
    }
    _isLive = true;
    _viewEnd = null;
    notifyListeners();
  }

  /// TODO this isn't used anywhere
  /// Snap to live mode showing all data (fully zoomed out).
  void goLiveFullView() {
    _viewStart = 0;
    _viewEnd = null;
    _liveSpan = null;
    _isLive = true;
    notifyListeners();
  }

  /// Set a specific visible window (exits live mode).
  void setWindow(int start, int end) {
    _viewStart = math.max(0, start);
    _viewEnd = end;
    _isLive = false;
    _liveSpan = null;
    notifyListeners();
  }

  /// Get the effective visible range given total data size.
  (int start, int end) effectiveRange(int totalSamples) {
    if (_isLive || _viewEnd == null) {
      if (_liveSpan != null && _liveSpan! < totalSamples) {
        // Zoomed-in live mode: show last _liveSpan samples
        return (totalSamples - _liveSpan!, totalSamples);
      }
      // Full-width live mode
      return (0, totalSamples);
    }
    return (_viewStart, _viewEnd!.clamp(_viewStart + 1, totalSamples));
  }

  /// Pan by a delta in samples (negative = left, positive = right).
  void pan(int deltaSamples, int totalSamples) {
    final (s, e) = effectiveRange(totalSamples);
    final span = e - s;
    int newStart = s + deltaSamples;
    int newEnd = newStart + span;

    // Clamp to valid range
    if (newStart < 0) {
      newStart = 0;
      newEnd = span;
    }
    if (newEnd >= totalSamples) {
      // Snap to live if we pan to the right edge
      _liveSpan = span < totalSamples ? span : null;
      _viewStart = math.max(0, totalSamples - span);
      _viewEnd = null;
      _isLive = true;
      notifyListeners();
      return;
    }

    _viewStart = newStart;
    _viewEnd = newEnd;
    _isLive = false;
    _liveSpan = null;
    notifyListeners();
  }

  /// Zoom by a factor around a focal point (0.0 = left edge, 1.0 = right edge).
  void zoom(double factor, double focalFraction, int totalSamples) {
    final (s, e) = effectiveRange(totalSamples);
    final span = e - s;
    final newSpan = (span / factor).round().clamp(
      // Minimum ~50 samples visible (50ms at 1kHz)
      50,
      totalSamples,
    );

    final focal = s + (focalFraction * span).round();
    int newStart = focal - (focalFraction * newSpan).round();
    int newEnd = newStart + newSpan;

    if (newStart < 0) {
      newStart = 0;
      newEnd = newSpan;
    }
    if (newEnd >= totalSamples) {
      // At the right edge -- enter live mode with this span
      _liveSpan = newSpan < totalSamples ? newSpan : null;
      _viewStart = math.max(0, totalSamples - newSpan);
      _viewEnd = null;
      _isLive = true;
      notifyListeners();
      return;
    }

    _viewStart = newStart;
    _viewEnd = newEnd;
    _isLive = false;
    _liveSpan = null;
    notifyListeners();
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

class Minimap extends StatelessWidget {
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

  void _onPointerSignal(
    PointerSignalEvent event,
    double graphWidth,
    int totalSamples,
  ) {
    if (event is PointerScrollEvent) {
      if (totalSamples == 0 || graphWidth <= 0) return;

      final focalFrac = ((event.localPosition.dx - 8.0) / graphWidth).clamp(
        0.0,
        1.0,
      );
      final zoomFactor = event.scrollDelta.dy < 0 ? 1.2 : 1 / 1.2;
      graphCtrl.zoom(zoomFactor, focalFrac, totalSamples);
    }
  }

  void _onMinimapTap(TapDownDetails d, double graphWidth, int totalSamples) {
    if (totalSamples == 0 || graphWidth <= 0) return;
    const leftSpace = 8.0;
    final frac = ((d.localPosition.dx - leftSpace) / graphWidth).clamp(
      0.0,
      1.0,
    );
    final (s, e) = graphCtrl.effectiveRange(totalSamples);
    final span = e - s;
    final center = (frac * totalSamples).round();
    int newStart = center - span ~/ 2;
    int newEnd = newStart + span;
    if (newStart < 0) {
      newStart = 0;
      newEnd = span;
    }
    if (newEnd >= totalSamples) {
      // In live mode this snaps to live. In static mode it just clamps to the end.
      newEnd = totalSamples;
      newStart = newEnd - span;
      if (newStart < 0) newStart = 0;
      graphCtrl.setWindow(newStart, newEnd);
      // It's up to the controller's internal logic if it sets `isLive` to true.
      // We manually call goLive() if we hit the edge to match previous behavior,
      // but only if it's actually live data (which we can guess by the controller state).
      // A better way is to just let the controller handle it, but for now we mimic live_tab:
      if (graphCtrl.isLive || newEnd == totalSamples) {
        graphCtrl.goLive();
      }
      return;
    }
    graphCtrl.setWindow(newStart, newEnd);
  }

  void _onMinimapDrag(
    DragUpdateDetails d,
    double graphWidth,
    int totalSamples,
  ) {
    if (totalSamples == 0 || graphWidth <= 0) return;
    final samplesPerPixel = totalSamples / graphWidth;
    final deltaSamples = (d.delta.dx * samplesPerPixel).round();
    final (s, e) = graphCtrl.effectiveRange(totalSamples);
    final span = e - s;
    int newStart = s + deltaSamples;
    int newEnd = newStart + span;
    if (newStart < 0) {
      newStart = 0;
      newEnd = span;
    }
    if (newEnd >= totalSamples) {
      newEnd = totalSamples;
      newStart = newEnd - span;
      if (newStart < 0) newStart = 0;
      graphCtrl.setWindow(newStart, newEnd);
      if (graphCtrl.isLive || newEnd == totalSamples) {
        graphCtrl.goLive();
      }
      return;
    }
    graphCtrl.setWindow(newStart, newEnd);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphWidth =
            constraints.maxWidth - 8 - 56; // leftSpace + rightSpace
        return SizedBox(
          height: 32,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerSignal: (e) =>
                _onPointerSignal(e, graphWidth, dataSource.sampleCount),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) =>
                  _onMinimapTap(d, graphWidth, dataSource.sampleCount),
              onHorizontalDragUpdate: (d) =>
                  _onMinimapDrag(d, graphWidth, dataSource.sampleCount),
              child: ListenableBuilder(
                listenable: graphCtrl,
                builder: (context, _) => CustomPaint(
                  foregroundPainter: _MinimapPainter(
                    dataSource,
                    activeChannels,
                    graphCtrl,
                    channelColors,
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
  final List<int> _activeIndices;
  final GraphController _ctrl;
  final List<Color> _colors;

  _MinimapPainter(this._data, this._activeIndices, this._ctrl, this._colors)
    : super(repaint: _data);

  @override
  void paint(Canvas canvas, Size size) {
    const double leftSpace = 8;
    const double rightSpace = 56;
    const double vPad = 2;

    canvas.translate(leftSpace, vPad);
    final gw = size.width - leftSpace - rightSpace;
    final gh = size.height - vPad * 2;

    if (gw <= 0 || gh <= 0) return;

    // Background
    final bgPaint = Paint()..color = Colors.grey.shade200;
    canvas.drawRect(Rect.fromLTWH(0, 0, gw, gh), bgPaint);

    final totalSamples = _data.sampleCount;
    if (totalSamples == 0) return;

    // Compute global min/max (raw, tare-subtracted) for full data
    double rawMax = 10000;
    double rawMin = -10000;
    for (final ch in _activeIndices) {
      final mx = _data.getChannelMax(ch) - _data.getChannelTare(ch);
      final mn = _data.getChannelMin(ch) - _data.getChannelTare(ch);
      if (mx > rawMax) rawMax = mx;
      if (mn < rawMin) rawMin = mn;
    }

    final dataRange = rawMax - rawMin;
    if (dataRange <= 0) return;

    // Draw simplified waveform for each channel
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final int gwInt = gw.toInt();
    for (int i = 0; i < _activeIndices.length; i++) {
      final ch = _activeIndices[i];
      final line = _data.getChannelData(ch);
      if (line.isEmpty) continue;

      final tare = _data.getChannelTare(ch);

      final avgPath = Path();
      final envPath = Path();
      bool first = true;

      for (int px = 0; px < gwInt; px++) {
        final int sStart = px * totalSamples ~/ gwInt;
        final int sEnd = (px + 1) * totalSamples ~/ gwInt;
        if (sStart >= sEnd) continue;

        double total = 0;
        double minRaw = double.infinity;
        double maxRaw = double.negativeInfinity;

        for (int j = sStart; j < sEnd; j++) {
          final val = line[j].toDouble();
          total += val;
          if (val < minRaw) minRaw = val;
          if (val > maxRaw) maxRaw = val;
        }

        final avgRaw = total / (sEnd - sStart);

        final avgTared = avgRaw - tare;
        final minTared = minRaw - tare;
        final maxTared = maxRaw - tare;

        final avgY = (gh - (avgTared - rawMin) * gh / dataRange).clamp(0.0, gh);
        final minY = (gh - (minTared - rawMin) * gh / dataRange).clamp(0.0, gh);
        final maxY = (gh - (maxTared - rawMin) * gh / dataRange).clamp(0.0, gh);

        if (first) {
          avgPath.moveTo(px.toDouble(), avgY);
          envPath.moveTo(px.toDouble(), minY);
          envPath.lineTo(px.toDouble(), maxY);
          first = false;
        } else {
          avgPath.lineTo(px.toDouble(), avgY);
          envPath.moveTo(px.toDouble(), minY);
          envPath.lineTo(px.toDouble(), maxY);
        }
      }

      final chColor = _colors[ch % _colors.length];

      // Draw envelope first (lighter)
      pen.color = chColor.withAlpha(40); // very faint for minimap
      canvas.drawPath(envPath, pen..strokeWidth = 1.0);

      // Draw average line on top
      pen.color = chColor.withAlpha(180);
      canvas.drawPath(avgPath, pen..strokeWidth = 1.0);
    }

    // Viewport highlight
    final (viewStart, viewEnd) = _ctrl.effectiveRange(totalSamples);
    final double x1 = viewStart * gw / totalSamples;
    final double x2 = viewEnd * gw / totalSamples;

    // Dim areas outside viewport
    final dimPaint = Paint()..color = Colors.black.withAlpha(60);
    if (x1 > 0) canvas.drawRect(Rect.fromLTWH(0, 0, x1, gh), dimPaint);
    if (x2 < gw) canvas.drawRect(Rect.fromLTWH(x2, 0, gw - x2, gh), dimPaint);

    // Viewport border
    final vpBorder = Paint()
      ..color = Colors.deepPurple
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(Rect.fromLTRB(x1, 0, x2, gh), vpBorder);
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter oldDelegate) {
    // Only repaint if the viewport changed or data size changed
    return oldDelegate._data.sampleCount != _data.sampleCount ||
        oldDelegate._ctrl.viewStart != _ctrl.viewStart ||
        oldDelegate._ctrl.viewEnd != _ctrl.viewEnd;
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

  void _onScaleStart(ScaleStartDetails details) {
    final total = widget.data.sampleCount;
    if (total == 0) return;

    final (s, e) = widget.ctrl.effectiveRange(total);
    _panStartSample = s;
    _panEndSample = e;
    _panStartX = details.localFocalPoint.dx;
    _scaleStartSpan = (e - s).toDouble();
    _pinchFocalX = details.localFocalPoint.dx;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, double graphWidth) {
    final total = widget.data.sampleCount;
    if (total == 0 || _panStartSample == null || graphWidth <= 0) return;

    final origStart = _panStartSample!;
    final origEnd = _panEndSample!;
    final origSpan = origEnd - origStart;

    if (details.scale != 1.0 && _scaleStartSpan != null) {
      // Pinch zoom
      final newSpan = (_scaleStartSpan! / details.scale).round().clamp(
        50,
        total,
      );

      final focalFrac = (_pinchFocalX! / graphWidth).clamp(0.0, 1.0);
      final focalSample = origStart + (focalFrac * origSpan).round();

      int newStart = focalSample - (focalFrac * newSpan).round();
      int newEnd = (newStart + newSpan).round();

      if (newStart < 0) {
        newStart = 0;
        newEnd = newSpan;
      }
      if (newEnd >= total) {
        newEnd = total;
        newStart = math.max(0, total - newSpan);
      }

      widget.ctrl.setWindow(newStart, newEnd);
      if (newEnd >= total) widget.ctrl.goLive();
    } else {
      // Pan
      final dx = details.localFocalPoint.dx - _panStartX!;
      final samplesPerPixel = origSpan / graphWidth;
      final deltaSamples = -(dx * samplesPerPixel).round();

      int newStart = origStart + deltaSamples;
      int newEnd = (newStart + origSpan).round();

      if (newStart < 0) {
        newStart = 0;
        newEnd = origSpan;
      }
      if (newEnd >= total) {
        newEnd = total;
        newStart = math.max(0, total - origSpan);
        widget.ctrl.setWindow(newStart, newEnd);
        widget.ctrl.goLive();
        return;
      }

      widget.ctrl.setWindow(newStart, newEnd);
    }
  }

  void _onPointerSignal(PointerSignalEvent event, double graphWidth) {
    if (event is PointerScrollEvent) {
      final total = widget.data.sampleCount;
      if (total == 0 || graphWidth <= 0) return;

      final focalFrac = ((event.localPosition.dx - 8.0) / graphWidth).clamp(
        0.0,
        1.0,
      );
      final zoomFactor = event.scrollDelta.dy < 0 ? 1.2 : 1 / 1.2;
      widget.ctrl.zoom(zoomFactor, focalFrac, total);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphWidth = constraints.maxWidth - 8 - 56;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (e) => _onPointerSignal(e, graphWidth),
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

class GraphWorkspace extends StatelessWidget {
  final GraphDataSource data;
  final GraphController ctrl;
  final AppSettings settings;
  final bool showDerivative;
  final bool isLiveGraph;

  const GraphWorkspace({
    super.key,
    required this.data,
    required this.ctrl,
    required this.settings,
    this.showDerivative = false,
    this.isLiveGraph = true,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Column(
              children: [
                // Main force graph
                Expanded(
                  flex: showDerivative ? 6 : 10,
                  child: InteractiveGraphArea(
                    data: data,
                    ctrl: ctrl,
                    child: ListenableBuilder(
                      listenable: Listenable.merge([ctrl, data]),
                      builder: (context, _) => CustomPaint(
                        foregroundPainter: ForceGraphPainter(
                          data,
                          settings,
                          ctrl,
                          showXLabels: !showDerivative,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                ),
                // Derivative graph (when enabled)
                if (showDerivative)
                  Expanded(
                    flex: 4,
                    child: InteractiveGraphArea(
                      data: data,
                      ctrl: ctrl,
                      child: ListenableBuilder(
                        listenable: Listenable.merge([ctrl, data]),
                        builder: (context, _) => CustomPaint(
                          foregroundPainter: DerivativeGraphPainter(
                            data,
                            settings,
                            ctrl,
                          ),
                          size: Size.infinite,
                        ),
                      ),
                    ),
                  ),
                // Minimap
                ListenableBuilder(
                  listenable: data,
                  builder: (context, _) => Minimap(
                    dataSource: data,
                    activeChannels: settings.activeChannelIndices,
                    graphCtrl: ctrl,
                    channelColors: settings.activeChannelIndices
                        .map((i) => getChannelColor(i))
                        .toList(),
                  ),
                ),
              ],
            ),
            // LIVE button (appears when not following live edge)
            ListenableBuilder(
              listenable: ctrl,
              builder: (context, _) {
                if (ctrl.isLive || data.sampleCount == 0 || !isLiveGraph) {
                  return const SizedBox.shrink();
                }
                return Positioned(
                  right: 64,
                  top: 8,
                  child: FilledButton.tonalIcon(
                    onPressed: ctrl.goLive,
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
                    heroTag: 'zoomIn_${data.hashCode}',
                    onPressed: () {
                      if (data.sampleCount > 0) {
                        final focal = ctrl.isLive ? 1.0 : 0.5;
                        ctrl.zoom(1.2, focal, data.sampleCount);
                      }
                    },
                    child: const Icon(Icons.zoom_in),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'zoomOut_${data.hashCode}',
                    onPressed: () {
                      if (data.sampleCount > 0) {
                        final focal = ctrl.isLive ? 1.0 : 0.5;
                        ctrl.zoom(1 / 1.2, focal, data.sampleCount);
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
  if (sec < 60) return sec.toString();
  final s = (sec % 60 < 10) ? '0' : '';
  return '${sec ~/ 60}:$s${sec % 60}';
}

/// Format fractional seconds for sub-second X labels.
String _fmtTimeFrac(double sec) {
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

({double yMin, double yMax, double tickDelta}) _computeYRange(
  double dataMin,
  double dataMax,
) {
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
// Live graph painter (force)
// ---------------------------------------------------------------------------

class ForceGraphPainter extends CustomPainter {
  final GraphDataSource _data;
  final AppSettings _settings;
  final GraphController _ctrl;
  final bool showXLabels;

  ForceGraphPainter(
    this._data,
    this._settings,
    this._ctrl, {
    this.showXLabels = true,
  }) : super(repaint: _data);

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = Colors.deepPurple
      ..style = PaintingStyle.stroke;

    const double leftSpace = 8;
    const double rightSpace = 56;
    const double bottomSpace = 24;
    const double topSpace = 4;

    canvas.translate(leftSpace, topSpace);
    final graphSz = Size(
      size.width - leftSpace - rightSpace,
      size.height - (showXLabels ? bottomSpace : 4) - topSpace,
    );

    if (graphSz.width <= 0 || graphSz.height <= 0) return;

    canvas.drawRect(
      Rect.fromLTRB(0, 0, graphSz.width, graphSz.height),
      pen..strokeWidth = 0.5,
    );

    if (_data.sampleCount == 0) return;

    final unit = _settings.displayUnit;
    final activeIndices = _settings.activeChannelIndices;
    final (viewStart, viewEnd) = _ctrl.effectiveRange(_data.sampleCount);
    final viewSamples = viewEnd - viewStart;
    if (viewSamples <= 0) return;

    // Compute data min/max across active channels in visible window (raw, tare-subtracted).
    // Start with actual extremes then enforce a minimum visible range.
    double rawMax = 0;
    double rawMin = 0;
    bool hasData = false;

    if (_ctrl.isLive && viewStart == 0) {
      // Full view -- use pre-tracked global min/max (O(1))
      for (final ch in activeIndices) {
        final mx = (_data.getChannelMax(ch) - _data.getChannelTare(ch))
            .toDouble();
        final mn = (_data.getChannelMin(ch) - _data.getChannelTare(ch))
            .toDouble();
        if (!hasData || mx > rawMax) rawMax = mx;
        if (!hasData || mn < rawMin) rawMin = mn;
        hasData = true;
      }
    } else {
      // Zoomed/panned -- scan visible window for actual min/max
      for (final ch in activeIndices) {
        final line = _data.getChannelData(ch);
        if (line.isEmpty) continue;
        final tare = _data.getChannelTare(ch);
        for (int i = viewStart; i < viewEnd; i++) {
          final v = line[i] - tare;
          if (!hasData || v > rawMax) rawMax = v.toDouble();
          if (!hasData || v < rawMin) rawMin = v.toDouble();
          hasData = true;
        }
      }
    }

    // Enforce a minimum visible range (noise floor) so the graph isn't degenerate
    const double noiseFloor = 10000; // raw counts
    if (rawMax - rawMin < noiseFloor) {
      final mid = (rawMax + rawMin) / 2;
      rawMax = mid + noiseFloor / 2;
      rawMin = mid - noiseFloor / 2;
    }

    final double dataMaxUnit = unit.fromKgf(rawMax * _data.calibrationSlope);
    final double dataMinUnit = unit.fromKgf(rawMin * _data.calibrationSlope);

    // Compute nice Y axis range
    final yRange = _computeYRange(dataMinUnit, dataMaxUnit);

    // Map a value in display units to Y pixel
    double unitToY(double val) {
      return graphSz.height -
          (val - yRange.yMin) * graphSz.height / (yRange.yMax - yRange.yMin);
    }

    // -- Grid and labels --
    final grid = Path();

    // X axis
    final double xSpanSec = viewSamples / _data.sampleRate;

    if (xSpanSec < 1.0) {
      // Sub-second: use fractional labels
      final stepMs = xSpanSec * 1000 / 5; // aim for ~5 labels
      final niceStepMs = _niceNum(stepMs);
      final startSec = viewStart / _data.sampleRate;

      final firstTickMs = ((startSec * 1000 / niceStepMs).ceil() * niceStepMs);
      for (
        double tMs = firstTickMs;
        tMs < (viewEnd / _data.sampleRate) * 1000;
        tMs += niceStepMs
      ) {
        final tSec = tMs / 1000;
        final xPos =
            (tSec - startSec) * _data.sampleRate * graphSz.width / viewSamples;
        grid.moveTo(xPos, 0);
        grid.lineTo(xPos, graphSz.height);
        if (showXLabels) {
          final par = _prepareLabel(_fmtTimeFrac(tSec));
          canvas.drawParagraph(
            par,
            Offset(xPos - par.longestLine / 2, graphSz.height + 2),
          );
        }
      }
    } else {
      final xC = _findScale(xSpanSec, _xScaleConfig);
      final double startSec = viewStart / _data.sampleRate;

      // Major grid + labels
      final int firstTick = ((startSec / xC.delta).ceil() * xC.delta).toInt();
      final double endSec = viewEnd / _data.sampleRate;
      for (int sec = firstTick; sec.toDouble() < endSec; sec += xC.delta) {
        final double xPos =
            (sec - startSec) * _data.sampleRate * graphSz.width / viewSamples;
        grid.moveTo(xPos, 0);
        grid.lineTo(xPos, graphSz.height);
        if (showXLabels) {
          final par = _prepareLabel(_fmtTime(sec));
          canvas.drawParagraph(
            par,
            Offset(xPos - par.longestLine / 2, graphSz.height + 2),
          );
        }
      }

      // Minor grid (half delta)
      final double minorDeltaSec = xC.delta / 2;
      final double firstMinor =
          (startSec / minorDeltaSec).ceil() * minorDeltaSec;
      for (double sec = firstMinor; sec < endSec; sec += minorDeltaSec) {
        final double xPos =
            (sec - startSec) * _data.sampleRate * graphSz.width / viewSamples;
        grid.moveTo(xPos, 0);
        grid.lineTo(xPos, graphSz.height);
      }
    }

    // Y axis grid + labels
    {
      final delta = yRange.tickDelta;
      // Start from the first tick at or above yMin
      double tick = (yRange.yMin / delta).ceil() * delta;
      while (tick <= yRange.yMax + delta * 0.01) {
        final yPos = unitToY(tick);
        if (yPos >= -1 && yPos <= graphSz.height + 1) {
          grid.moveTo(0, yPos);
          grid.lineTo(graphSz.width, yPos);

          // Label
          final labelStr = _formatTickLabel(tick, unit.symbol);
          final par = _prepareLabel(labelStr);
          canvas.drawParagraph(
            par,
            Offset(graphSz.width + 4, yPos - par.height / 2),
          );
        }
        tick += delta;
      }

      // Minor grid (half delta)
      final minorDelta = delta / 2;
      double minorTick = (yRange.yMin / minorDelta).ceil() * minorDelta;
      while (minorTick <= yRange.yMax + minorDelta * 0.01) {
        final yPos = unitToY(minorTick);
        if (yPos >= -1 && yPos <= graphSz.height + 1) {
          grid.moveTo(0, yPos);
          grid.lineTo(graphSz.width, yPos);
        }
        minorTick += minorDelta;
      }
    }

    canvas.drawPath(grid, pen..strokeWidth = 0.2);

    // -- Zero baseline --
    if (yRange.yMin < 0 && yRange.yMax > 0) {
      final zeroY = unitToY(0);
      final zeroPaint = Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8;
      canvas.drawLine(
        Offset(0, zeroY),
        Offset(graphSz.width, zeroY),
        zeroPaint,
      );
    }

    // -- Data lines --
    final rawRange = yRange.yMax - yRange.yMin;
    final slopeToUnit =
        _data.calibrationSlope *
        (unit == ForceUnit.kgf
            ? 1.0
            : unit == ForceUnit.n
            ? 9.80665
            : unit == ForceUnit.kN
            ? 9.80665 / 1000.0
            : 2.20462);

    for (final ch in activeIndices) {
      final line = _data.getChannelData(ch);
      if (line.isEmpty) continue;
      final tare = _data.getChannelTare(ch);

      final avgPath = Path();
      final envPath = Path();
      final int graphW = graphSz.width.toInt();
      bool first = true;

      for (int i = 0; i < graphW; ++i) {
        // Map pixel i to sample range
        final int sStart = viewStart + (i * viewSamples ~/ graphW);
        final int sEnd = viewStart + ((i + 1) * viewSamples ~/ graphW);
        if (sStart >= sEnd) continue;

        double total = 0;
        double minRaw = double.infinity;
        double maxRaw = double.negativeInfinity;

        for (int j = sStart; j < sEnd; j++) {
          final val = line[j];
          total += val;
          if (val < minRaw) minRaw = val.toDouble();
          if (val > maxRaw) maxRaw = val.toDouble();
        }

        final avgRaw = total / (sEnd - sStart);

        final avgUnit = (avgRaw - tare) * slopeToUnit;
        final minUnit = (minRaw - tare) * slopeToUnit;
        final maxUnit = (maxRaw - tare) * slopeToUnit;

        final avgY =
            (graphSz.height -
                    (avgUnit - yRange.yMin) * graphSz.height / rawRange)
                .clamp(0.0, graphSz.height);
        final minY =
            (graphSz.height -
                    (minUnit - yRange.yMin) * graphSz.height / rawRange)
                .clamp(0.0, graphSz.height);
        final maxY =
            (graphSz.height -
                    (maxUnit - yRange.yMin) * graphSz.height / rawRange)
                .clamp(0.0, graphSz.height);

        if (first) {
          avgPath.moveTo(i.toDouble(), avgY);
          envPath.moveTo(i.toDouble(), minY);
          envPath.lineTo(i.toDouble(), maxY);
          first = false;
        } else {
          avgPath.lineTo(i.toDouble(), avgY);
          envPath.moveTo(i.toDouble(), minY);
          envPath.lineTo(i.toDouble(), maxY);
        }
      }

      final chColor = getChannelColor(ch);

      // Draw envelope first (lighter)
      pen.color = chColor.withAlpha(60);
      canvas.drawPath(envPath, pen..strokeWidth = 1.0);

      // Draw average line on top
      pen.color = chColor;
      canvas.drawPath(avgPath, pen..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Derivative graph painter
// ---------------------------------------------------------------------------

class DerivativeGraphPainter extends CustomPainter {
  final GraphDataSource _data;
  final AppSettings _settings;
  final GraphController _ctrl;

  DerivativeGraphPainter(this._data, this._settings, this._ctrl)
    : super(repaint: _data);

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = Colors.deepPurple
      ..style = PaintingStyle.stroke;

    const double leftSpace = 8;
    const double rightSpace = 56;
    const double bottomSpace = 24;
    const double topSpace = 2;

    canvas.translate(leftSpace, topSpace);
    final graphSz = Size(
      size.width - leftSpace - rightSpace,
      size.height - bottomSpace - topSpace,
    );

    if (graphSz.width <= 0 || graphSz.height <= 0) return;

    canvas.drawRect(
      Rect.fromLTRB(0, 0, graphSz.width, graphSz.height),
      pen..strokeWidth = 0.5,
    );

    if (_data.sampleCount < 2) return;

    final unit = _settings.displayUnit;
    final activeIndices = _settings.activeChannelIndices;
    final (viewStart, viewEnd) = _ctrl.effectiveRange(_data.sampleCount);
    final viewSamples = viewEnd - viewStart;
    if (viewSamples < 2) return;

    final double slopeToUnit =
        _data.calibrationSlope *
        (unit == ForceUnit.kgf
            ? 1.0
            : unit == ForceUnit.n
            ? 9.80665
            : unit == ForceUnit.kN
            ? 9.80665 / 1000.0
            : 2.20462);
    final double sampleRate = _data.sampleRate.toDouble();

    // Compute derivative min/max in visible window
    double dMin = 0;
    double dMax = 0;
    bool first = true;
    for (final ch in activeIndices) {
      final line = _data.getChannelData(ch);
      if (line.isEmpty) continue;

      final startI = math.max(viewStart, 1);
      for (int i = startI; i < viewEnd; i++) {
        final d = (line[i] - line[i - 1]).toDouble() * slopeToUnit * sampleRate;
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

    // Add some padding
    if (dMax - dMin < 0.001) {
      dMax = dMin + 1.0;
    }

    final yRange = _computeYRange(dMin, dMax);

    double valToY(double val) {
      return graphSz.height -
          (val - yRange.yMin) * graphSz.height / (yRange.yMax - yRange.yMin);
    }

    // Grid + labels
    final grid = Path();

    // X axis labels
    final double xSpanSec = viewSamples / _data.sampleRate;
    final double startSec = viewStart / _data.sampleRate;
    final double endSec = viewEnd / _data.sampleRate;

    if (xSpanSec < 1.0) {
      final stepMs = xSpanSec * 1000 / 5;
      final niceStepMs = _niceNum(stepMs);
      final firstTickMs = ((startSec * 1000 / niceStepMs).ceil() * niceStepMs);
      for (double tMs = firstTickMs; tMs < endSec * 1000; tMs += niceStepMs) {
        final tSec = tMs / 1000;
        final xPos =
            (tSec - startSec) * _data.sampleRate * graphSz.width / viewSamples;
        grid.moveTo(xPos, 0);
        grid.lineTo(xPos, graphSz.height);
        final par = _prepareLabel(_fmtTimeFrac(tSec));
        canvas.drawParagraph(
          par,
          Offset(xPos - par.longestLine / 2, graphSz.height + 2),
        );
      }
    } else {
      final xC = _findScale(xSpanSec, _xScaleConfig);
      final int firstTick = ((startSec / xC.delta).ceil() * xC.delta).toInt();
      for (int sec = firstTick; sec.toDouble() < endSec; sec += xC.delta) {
        final double xPos =
            (sec - startSec) * _data.sampleRate * graphSz.width / viewSamples;
        grid.moveTo(xPos, 0);
        grid.lineTo(xPos, graphSz.height);
        final par = _prepareLabel(_fmtTime(sec));
        canvas.drawParagraph(
          par,
          Offset(xPos - par.longestLine / 2, graphSz.height + 2),
        );
      }
    }

    // Y axis grid + labels
    {
      final delta = yRange.tickDelta;
      double tick = (yRange.yMin / delta).ceil() * delta;
      while (tick <= yRange.yMax + delta * 0.01) {
        final yPos = valToY(tick);
        if (yPos >= -1 && yPos <= graphSz.height + 1) {
          grid.moveTo(0, yPos);
          grid.lineTo(graphSz.width, yPos);

          final labelStr = '${_formatTickValue(tick)}/s';
          final par = _prepareLabel(labelStr);
          canvas.drawParagraph(
            par,
            Offset(graphSz.width + 4, yPos - par.height / 2),
          );
        }
        tick += delta;
      }
    }

    canvas.drawPath(grid, pen..strokeWidth = 0.2);

    // Zero baseline
    if (yRange.yMin < 0 && yRange.yMax > 0) {
      final zeroY = valToY(0);
      final zeroPaint = Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8;
      canvas.drawLine(
        Offset(0, zeroY),
        Offset(graphSz.width, zeroY),
        zeroPaint,
      );
    }

    // "dF/dt" label in top-left
    final dLabel = _prepareLabel(
      'dF/dt (${unit.symbol}/s)',
      color: Colors.black45,
    );
    canvas.drawParagraph(dLabel, const Offset(4, 2));

    // Data lines
    final rawYRange = yRange.yMax - yRange.yMin;
    for (final ch in activeIndices) {
      final line = _data.getChannelData(ch);
      if (line.isEmpty) continue;

      final avgPath = Path();
      final envPath = Path();
      final int graphW = graphSz.width.toInt();
      bool pathFirst = true;

      for (int px = 0; px < graphW; ++px) {
        final int sStart = math.max(
          viewStart + (px * viewSamples ~/ graphW),
          1,
        );
        final int sEnd = math.max(
          viewStart + ((px + 1) * viewSamples ~/ graphW),
          2,
        );
        if (sStart >= sEnd || sStart >= _data.sampleCount) continue;

        double total = 0;
        int count = 0;
        double minDerivRaw = double.infinity;
        double maxDerivRaw = double.negativeInfinity;

        for (int j = sStart; j < sEnd && j < _data.sampleCount; j++) {
          final double d = (line[j] - line[j - 1]).toDouble();
          total += d;
          count++;
          if (d < minDerivRaw) minDerivRaw = d;
          if (d > maxDerivRaw) maxDerivRaw = d;
        }
        if (count == 0) continue;

        final avgDerivRaw = total / count;

        final avgDerivUnit = avgDerivRaw * slopeToUnit * sampleRate;
        final minDerivUnit = minDerivRaw * slopeToUnit * sampleRate;
        final maxDerivUnit = maxDerivRaw * slopeToUnit * sampleRate;

        final avgY =
            (graphSz.height -
                    (avgDerivUnit - yRange.yMin) * graphSz.height / rawYRange)
                .clamp(0.0, graphSz.height);
        final minY =
            (graphSz.height -
                    (minDerivUnit - yRange.yMin) * graphSz.height / rawYRange)
                .clamp(0.0, graphSz.height);
        final maxY =
            (graphSz.height -
                    (maxDerivUnit - yRange.yMin) * graphSz.height / rawYRange)
                .clamp(0.0, graphSz.height);

        if (pathFirst) {
          avgPath.moveTo(px.toDouble(), avgY);
          envPath.moveTo(px.toDouble(), minY);
          envPath.lineTo(px.toDouble(), maxY);
          pathFirst = false;
        } else {
          avgPath.lineTo(px.toDouble(), avgY);
          envPath.moveTo(px.toDouble(), minY);
          envPath.lineTo(px.toDouble(), maxY);
        }
      }

      final chColor = getChannelColor(ch);

      // Envelope
      pen.color = chColor.withAlpha(60);
      canvas.drawPath(envPath, pen..strokeWidth = 1.0);

      // Average
      pen.color = chColor;
      canvas.drawPath(avgPath, pen..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
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
