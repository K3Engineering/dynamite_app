import 'package:flutter/material.dart';

import '../models/force_unit.dart';
import 'graph_components.dart' show getChannelColor;

/// One row of per-channel values in a [ChannelStatsTable].
class ChannelStatsRow {
  const ChannelStatsRow({
    required this.label,
    required this.values,
    this.emphasized = false,
    this.stale = false,
  });

  /// Row label shown in the leading column ('Live', 'Peak', ...).
  final String label;

  /// One value per channel, in [ChannelStatsTable.unit] units.
  final List<double> values;

  /// Primary-reading styling (larger, bold) — e.g. the live value row.
  final bool emphasized;

  /// Dim the values: the reading is stale (e.g. a live data gap).
  final bool stale;
}

/// Tappable per-channel header shared by the live view and the session
/// detail view: channel labels with color swatches on top, then one row of
/// stats per [ChannelStatsRow]. Tapping any channel cell toggles that
/// channel via [onToggleChannel]; the owner decides what the toggle means
/// (live-tab setting, per-session visibility, ...).
class ChannelStatsTable extends StatelessWidget {
  ChannelStatsTable({
    super.key,
    required this.labels,
    required this.activeChannels,
    required this.onToggleChannel,
    required this.unit,
    required this.rows,
  }) : assert(
         _oneValuePerChannel(labels, activeChannels, rows),
         'labels, activeChannels and every row must have the same length',
       );

  static bool _oneValuePerChannel(
    List<String> labels,
    List<bool> activeChannels,
    List<ChannelStatsRow> rows,
  ) =>
      activeChannels.length == labels.length &&
      rows.every((r) => r.values.length == labels.length);

  /// Display label per channel.
  final List<String> labels;

  /// Whether each channel is currently enabled. Inactive channels show
  /// '--' and are dimmed.
  final List<bool> activeChannels;

  /// Called with the channel index when any of its cells is tapped.
  final ValueChanged<int> onToggleChannel;

  /// Unit the row [ChannelStatsRow.values] are expressed in.
  final ForceUnit unit;

  /// Stat rows below the channel header.
  final List<ChannelStatsRow> rows;

  @override
  Widget build(BuildContext context) {
    final channelCount = labels.length;
    final staleColor = Theme.of(context).colorScheme.outline;
    final headerStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold);
    // Tabular figures keep the numeric columns aligned using the platform's
    // default font — no bundled font assets and no runtime font fetch.
    const tabularFigures = [FontFeature.tabularFigures()];
    final monoStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFeatures: tabularFigures);
    final emphasizedStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.bold,
      fontFeatures: tabularFigures,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Stack(
        children: [
          Table(
            columnWidths: {
              0: const IntrinsicColumnWidth(), // Row labels
              for (int i = 1; i <= channelCount; i++)
                i: const FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              // -----------------------------------------------------------
              // Channel Labels
              // -----------------------------------------------------------
              TableRow(
                children: [
                  const SizedBox.shrink(), // Empty top-left corner
                  for (int i = 0; i < channelCount; i++)
                    _TappableChannelCell(
                      onTap: () => onToggleChannel(i),
                      child: Padding(
                        padding: const EdgeInsets.only(
                          bottom: 4,
                          left: 4,
                          right: 4,
                        ),
                        child: Text(
                          labels[i],
                          textAlign: TextAlign.right,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: activeChannels[i]
                                    ? getChannelColor(i)
                                    : staleColor.withValues(alpha: 0.5),
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                ],
              ),
              // -----------------------------------------------------------
              // Horizontal Colored Lines
              // -----------------------------------------------------------
              TableRow(
                children: [
                  const SizedBox.shrink(),
                  for (int i = 0; i < channelCount; i++)
                    _TappableChannelCell(
                      onTap: () => onToggleChannel(i),
                      child: Padding(
                        padding: const EdgeInsets.only(
                          bottom: 8,
                          left: 2,
                          right: 2,
                        ),
                        child: Container(
                          height: 3,
                          color: activeChannels[i]
                              ? getChannelColor(i)
                              : staleColor.withValues(alpha: 0.3),
                        ),
                      ),
                    ),
                ],
              ),
              // -----------------------------------------------------------
              // Stat rows
              // -----------------------------------------------------------
              for (final row in rows)
                TableRow(
                  children: [
                    Text(row.label, style: headerStyle),
                    for (int i = 0; i < channelCount; i++)
                      _TableCellValue(
                        value: row.values[i],
                        unit: unit,
                        isActive: activeChannels[i],
                        isStale: row.stale,
                        textStyle: row.emphasized ? emphasizedStyle : monoStyle,
                        onTap: () => onToggleChannel(i),
                      ),
                  ],
                ),
            ],
          ),
          // Unit overlay, anchored to the top-left corner, sitting just
          // below the channel labels and above the first stat row.
          Positioned(
            top: 13,
            left: 0,
            child: Text('In ${unit.symbol}', style: headerStyle),
          ),
        ],
      ),
    );
  }
}

/// Shared tap-target wrapper for every channel cell (label, color bar, stat
/// value): pointer cursor + opaque hit testing + the toggle callback, so the
/// hit behavior can't drift between cell kinds.
class _TappableChannelCell extends StatelessWidget {
  const _TappableChannelCell({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    );
  }
}

class _TableCellValue extends StatelessWidget {
  const _TableCellValue({
    required this.value,
    required this.unit,
    required this.isActive,
    required this.isStale,
    required this.textStyle,
    this.onTap,
  });

  final double value;
  final ForceUnit unit;
  final bool isActive;
  final bool isStale;
  final TextStyle? textStyle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final staleColor = Theme.of(context).colorScheme.outline;

    // If inactive, show dashes and dim it heavily. If active but stale, dim
    // it lightly.
    final String displayText = isActive ? unit.formatValueOnly(value) : '--';
    final color = !isActive
        ? staleColor.withValues(alpha: 0.4)
        : (isStale ? staleColor : null);

    return _TappableChannelCell(
      onTap: onTap ?? () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 1),
        child: Text(
          displayText,
          textAlign: TextAlign.right,
          style: textStyle?.copyWith(color: color),
          maxLines: 1,
          overflow: TextOverflow.visible,
        ),
      ),
    );
  }
}
