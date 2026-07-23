import 'package:flutter/material.dart';

/// Map RSSI (dBm) to a 0–3 signal level for [RssiIndicator]'s bars icon.
/// Thresholds suit a nearby BLE sensor (the load cell sits within a few
/// meters): strong ≥ −55, good ≥ −65, fair ≥ −75, weak below.
int rssiLevel(int rssi) => rssi >= -55
    ? 3
    : rssi >= -65
    ? 2
    : rssi >= -75
    ? 1
    : 0;

/// Compact live signal-strength readout for the connected device: a bars
/// icon plus the exact dBm value, refreshed by BleLinkManager's RSSI polling.
/// Renders nothing when [rssi] is null — before the first poll lands, or on
/// platforms without readRssi (web) — so no surface ever shows a permanent
/// placeholder where no reading can exist.
class RssiIndicator extends StatelessWidget {
  const RssiIndicator({
    required this.rssi,
    this.color,
    this.size = 16,
    super.key,
  });

  /// Latest polled RSSI (dBm); null hides the indicator entirely.
  final int? rssi;

  /// Icon color. Pass explicitly on tinted surfaces (e.g. the connected
  /// device row's primaryContainer), where the default IconTheme color is
  /// wrong. Defaults to the ambient IconTheme color.
  final Color? color;

  /// Icon edge (logical px); sized to sit inside a ListTile subtitle.
  final double size;

  @override
  Widget build(BuildContext context) {
    final rssi = this.rssi;
    if (rssi == null) return const SizedBox.shrink();
    final icon = switch (rssiLevel(rssi)) {
      3 => Icons.signal_cellular_alt,
      2 => Icons.signal_cellular_alt_2_bar,
      1 => Icons.signal_cellular_alt_1_bar,
      _ => Icons.signal_cellular_0_bar,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: size, color: color),
        const SizedBox(width: 4),
        // Inherit the ambient text style (e.g. the ListTile subtitle style).
        Text('$rssi dBm', style: DefaultTextStyle.of(context).style),
      ],
    );
  }
}
