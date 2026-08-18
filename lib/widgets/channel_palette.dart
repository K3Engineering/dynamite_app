import 'package:material_ui/material_ui.dart';

/// Per-channel color, shared by the graphs and the stats tables so one
/// channel reads as the same color everywhere.
Color getChannelColor(int index) {
  const colors = [
    Colors.blueAccent,
    Colors.deepOrangeAccent,
    Colors.green,
    Colors.purple,
  ];
  return colors[index % colors.length];
}
