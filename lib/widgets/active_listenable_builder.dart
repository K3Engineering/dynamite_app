import 'package:flutter/widgets.dart';

/// A [ListenableBuilder] that subscribes to [listenable] only while [active]
/// is true: while inactive the subtree does not rebuild on notifications, so
/// a hidden tab schedules no frames for them. The rebuild that flips [active]
/// back on re-runs [builder], so the child is current on return.
class ActiveListenableBuilder extends StatefulWidget {
  const ActiveListenableBuilder({
    super.key,
    required this.active,
    required this.listenable,
    required this.builder,
  });

  final bool active;
  final Listenable listenable;
  final WidgetBuilder builder;

  @override
  State<ActiveListenableBuilder> createState() =>
      _ActiveListenableBuilderState();
}

class _ActiveListenableBuilderState extends State<ActiveListenableBuilder> {
  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(ActiveListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_onNotify);
      _subscribe();
    }
  }

  void _subscribe() {
    if (widget.active) widget.listenable.addListener(_onNotify);
  }

  void _onNotify() => setState(() {});

  @override
  void dispose() {
    widget.listenable.removeListener(_onNotify);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
