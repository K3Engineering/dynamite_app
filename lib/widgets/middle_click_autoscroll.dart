import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// Press-and-hold middle-mouse autoscroll for a vertical scrollable.
///
/// Flutter has no middle-button scrolling on any platform, and on web the
/// engine also suppresses Chrome's native autoscroll, so the gesture is
/// reimplemented here. Tracked upstream:
/// https://github.com/flutter/flutter/issues/66537
class MiddleClickAutoscroll extends StatefulWidget {
  const MiddleClickAutoscroll({
    super.key,
    required this.controller,
    required this.child,
  });

  /// Must be the same instance attached to the child scrollable.
  final ScrollController controller;

  final Widget child;

  @override
  State<MiddleClickAutoscroll> createState() => _MiddleClickAutoscrollState();
}

class _MiddleClickAutoscrollState extends State<MiddleClickAutoscroll>
    with SingleTickerProviderStateMixin {
  static const double _deadZoneRadius = 10;

  /// Scroll speed in px/s per pixel of distance from the press point.
  static const double _speedGain = 6;

  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastElapsed = Duration.zero;

  Offset? _pressOffset;
  double _pxPerSecond = 0;

  bool get _engaged => _pressOffset != null;

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons != kMiddleMouseButton) return;
    _lastElapsed = Duration.zero;
    _ticker.start();
    setState(() => _pressOffset = event.position);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_engaged) return;
    if (event.buttons & kMiddleMouseButton == 0) {
      // Flutter only emits "up" when all buttons lift; releasing the middle
      // button while another is still held arrives as a move.
      _disengage();
      return;
    }
    final offset = event.position.dy - _pressOffset!.dy;
    _pxPerSecond = offset.abs() < _deadZoneRadius ? 0 : offset * _speedGain;
  }

  void _disengage() {
    _pressOffset = null;
    _pxPerSecond = 0;
    _ticker.stop();
    setState(() {});
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    if (_pxPerSecond == 0 || !widget.controller.hasClients) return;
    final position = widget.controller.position;
    position.moveTo(
      position.pixels +
          _pxPerSecond * dt.inMicroseconds / Duration.microsecondsPerSecond,
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _disengage(),
      onPointerCancel: (_) => _disengage(),
      child: MouseRegion(
        cursor: _engaged ? SystemMouseCursors.grabbing : MouseCursor.defer,
        child: widget.child,
      ),
    );
  }
}
