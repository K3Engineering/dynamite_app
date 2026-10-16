import 'package:material_ui/material_ui.dart';

/// Per-channel color, shared by the graphs and the stats tables so one
/// channel reads as the same color everywhere. Ids 0..3 are the hardware
/// channels, 4.. the derived channels (see `derived_channel.dart`).
Color getChannelColor(int index) {
  const colors = [
    Colors.blueAccent,
    Colors.deepOrangeAccent,
    Colors.green,
    Colors.purple,
    Colors.teal,
    Colors.pinkAccent,
    Colors.amber,
    Colors.cyan,
  ];
  return colors[index % colors.length];
}
