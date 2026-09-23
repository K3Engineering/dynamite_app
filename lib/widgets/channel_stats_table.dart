import 'package:material_ui/material_ui.dart';

import '../models/display_unit.dart';
import '../models/load_cell.dart';
import 'channel_palette.dart';

class ChannelStatsRow {
  const ChannelStatsRow({
    required this.label,
    required this.values,
    this.emphasized = false,
    this.stale = false,
  });

  /// Row label shown in the leading column.
  final String label;

  /// One value per channel, in [ChannelStatsTable.unit] units; null means the
  /// unit is unavailable (renders '—').
  final List<double?> values;

  /// Primary-reading styling (larger, bold).
  final bool emphasized;

  /// Dim the values (a stale reading).
  final bool stale;
}

/// Tappable per-channel header; the owner decides what the toggle means.
class ChannelStatsTable extends StatelessWidget {
  ChannelStatsTable({
    super.key,
    required this.labels,
    required this.activeChannels,
    required this.onToggleChannel,
    required this.unit,
    required this.rows,
    this.clipped,
  }) : assert(
         _oneValuePerChannel(labels, activeChannels, rows, clipped),
         'labels, activeChannels, rows and clipped must agree in length',
       );

  static bool _oneValuePerChannel(
    List<String> labels,
    List<bool> activeChannels,
    List<ChannelStatsRow> rows,
    List<bool>? clipped,
  ) =>
      activeChannels.length == labels.length &&
      rows.every((r) => r.values.length == labels.length) &&
      (clipped == null || clipped.length == labels.length);

  final List<String> labels;

  /// Whether each channel is enabled; inactive ones show '--' and are dimmed.
  final List<bool> activeChannels;

  /// Called with the channel index when any of its cells is tapped.
  final ValueChanged<int> onToggleChannel;

  /// Unit the row [ChannelStatsRow.values] are expressed in.
  final DisplayUnit unit;

  /// Stat rows below the channel header.
  final List<ChannelStatsRow> rows;

  /// Per-channel ADC-rail flag; null = no status display.
  final List<bool>? clipped;

  static Widget? _statusIcon({
    required bool clipped,
    required bool active,
    required int channel,
  }) {
    if (!active) return null;
    return _ClipStatusIcon(clipped: clipped, channel: channel);
  }

  @override
  Widget build(BuildContext context) {
    final channelCount = labels.length;
    final staleColor = Theme.of(context).colorScheme.outline;
    final headerStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold);
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
              TableRow(
                children: [
                  const SizedBox.shrink(), // Empty top-left corner
                  for (int i = 0; i < channelCount; i++)
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: 4,
                        left: 4,
                        right: 4,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          // Fixed-width slot so the label never reflows;
                          // outside the toggle so a tap shows the tooltip.
                          SizedBox(
                            width: 20,
                            height: 16,
                            child: _statusIcon(
                              clipped: clipped?[i] ?? false,
                              active: activeChannels[i],
                              channel: i,
                            ),
                          ),
                          Flexible(
                            child: _TappableChannelCell(
                              channel: i,
                              active: activeChannels[i],
                              onTap: () => onToggleChannel(i),
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
                    ),
                ],
              ),
              TableRow(
                children: [
                  const SizedBox.shrink(),
                  for (int i = 0; i < channelCount; i++)
                    _TappableChannelCell(
                      channel: i,
                      active: activeChannels[i],
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
              for (final row in rows)
                TableRow(
                  children: [
                    Text(row.label, style: headerStyle),
                    for (int i = 0; i < channelCount; i++)
                      _TableCellValue(
                        channel: i,
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

/// ADC-rail warning icon: snaps on at the first clipped sample and fades out
/// once clear, so a hovering rail reads as steady. The subtree unmounts when
/// faded (an opacity-zero tooltip trigger would still answer pointer hits).
class _ClipStatusIcon extends StatefulWidget {
  const _ClipStatusIcon({required this.clipped, required this.channel});

  /// Instantaneous rail flag.
  final bool clipped;
  final int channel;

  static const Duration _fadeOut = Duration(milliseconds: 800);

  @override
  State<_ClipStatusIcon> createState() => _ClipStatusIconState();
}

class _ClipStatusIconState extends State<_ClipStatusIcon> {
  /// Whether the icon is fully faded and unmounted. A never-clipped channel
  /// mounts nothing, and the initial zero-opacity build never animates, so
  /// [AnimatedOpacity.onEnd] alone can't be relied on.
  bool _gone = true;

  @override
  void initState() {
    super.initState();
    _gone = !widget.clipped;
  }

  @override
  void didUpdateWidget(_ClipStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The zero-duration fade-in makes the reappearance instant in this
    // build; no setState needed since a build follows didUpdateWidget.
    if (widget.clipped) _gone = false;
  }

  void _onFadeEnd() {
    if (!widget.clipped) setState(() => _gone = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.clipped && _gone) return const SizedBox.shrink();
    return AnimatedOpacity(
      opacity: widget.clipped ? 1.0 : 0.0,
      duration: widget.clipped ? Duration.zero : _ClipStatusIcon._fadeOut,
      onEnd: _onFadeEnd,
      child: Tooltip(
        message:
            '${rigSlotTitle(widget.channel)} is at the ADC rail. The reading is clipping.',
        triggerMode: TooltipTriggerMode.tap,
        child: Icon(
          Icons.warning_rounded,
          size: 14,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}

/// Tap-target wrapper for a channel cell: pointer cursor, opaque hit testing,
/// the toggle callback, and screen-reader semantics.
class _TappableChannelCell extends StatelessWidget {
  const _TappableChannelCell({
    required this.channel,
    required this.active,
    required this.onTap,
    required this.child,
  });

  final int channel;
  final bool active;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Semantics(
        button: true,
        toggled: active,
        label: rigSlotTitle(channel),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: child,
        ),
      ),
    );
  }
}

class _TableCellValue extends StatelessWidget {
  const _TableCellValue({
    required this.channel,
    required this.value,
    required this.unit,
    required this.isActive,
    required this.isStale,
    required this.textStyle,
    this.onTap,
  });

  final int channel;

  /// The value in [unit] units; null when unavailable (rendered '—').
  final double? value;
  final DisplayUnit unit;
  final bool isActive;
  final bool isStale;
  final TextStyle? textStyle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final staleColor = Theme.of(context).colorScheme.outline;
    final value = this.value;

    final String displayText = !isActive
        ? '--'
        : (value == null ? '—' : unit.formatValueOnly(value));
    final color = !isActive
        ? staleColor.withValues(alpha: 0.4)
        : ((isStale || value == null) ? staleColor : null);

    return _TappableChannelCell(
      channel: channel,
      active: isActive,
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
