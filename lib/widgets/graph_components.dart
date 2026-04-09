import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../screens/live_tab.dart' show GraphController;

/// Data interface required by the shared minimap.
/// This allows the minimap to render either live DataHub data or static SessionData.
abstract class MinimapDataSource {
  /// Total number of samples currently available.
  int get sampleCount;

  /// Returns the raw data array for a given channel index.
  List<int> getChannelData(int channelIndex);

  /// Returns the minimum raw value for a given channel index.
  double getChannelMin(int channelIndex);

  /// Returns the maximum raw value for a given channel index.
  double getChannelMax(int channelIndex);

  /// Returns the tare offset for a given channel index (0 for pre-tared data).
  double getChannelTare(int channelIndex);
}

class Minimap extends StatelessWidget {
  final MinimapDataSource dataSource;
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
  final MinimapDataSource _data;
  final List<int> _activeIndices;
  final GraphController _ctrl;
  final List<Color> _colors;

  _MinimapPainter(this._data, this._activeIndices, this._ctrl, this._colors);

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
