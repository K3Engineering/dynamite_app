import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../models/display_unit.dart';
import '../models/feed_health.dart';
import '../services/app_settings.dart';
import '../services/data_hub.dart';
import '../services/rig_state.dart';
import 'channel_palette.dart';

/// Per-channel tare control panel as a modal bottom sheet: each active
/// channel's live value and tare point (both in the current display
/// unit), with TARE/RESET per channel and ALL variants in the footer.
/// Actions act on the hub directly and the sheet stays open, so the new
/// offset is visible where it was requested.
///
/// A tare point cell doubles as manual entry: tap it to type the gross
/// point where zero sits — absolute, replacing the current offset
/// (`DataHub.setTarePoint`). Editing is unavailable while a sampled tare
/// fills its window.
Future<void> showTareSheet(
  BuildContext context, {
  required DataHub hub,
  required RigState rig,
  required AppSettings settings,
  required ValueListenable<FeedHealth?> health,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // So the in-sheet text field pushes the sheet above the keyboard.
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _TareSheet(hub: hub, rig: rig, settings: settings, health: health),
    ),
  );
}

class _TareSheet extends StatefulWidget {
  final DataHub hub;
  final RigState rig;
  final AppSettings settings;

  /// Same feed-health classification the live tab uses: when nothing new
  /// is arriving the sheet's live values are held readings and gray out.
  final ValueListenable<FeedHealth?> health;

  const _TareSheet({
    required this.hub,
    required this.rig,
    required this.settings,
    required this.health,
  });

  @override
  State<_TareSheet> createState() => _TareSheetState();
}

class _TareSheetState extends State<_TareSheet> {
  /// Channel whose tare point is being typed, or null when no edit is
  /// open. The controller/focus live across the hub's per-packet
  /// rebuilds; only one edit exists at a time.
  int? _editingChannel;
  TextEditingController? _editController;
  FocusNode? _editFocus;
  String? _editError;

  DataHub get hub => widget.hub;

  @override
  void dispose() {
    _editController?.dispose();
    _editFocus?.dispose();
    super.dispose();
  }

  void _startEdit(int ch, DisplayUnit unit) {
    // A filling tare window owns the offset until it commits — don't
    // open an edit the commit would overwrite (the buttons gray out the
    // same way).
    if (hub.taring) return;
    final current = hub.tarePoint(ch, unit);
    if (current == null) return; // '—': the unit can't convert here.
    final text = unit.formatValueOnly(current);
    // Focus comes from the field's autofocus once it mounts.
    final controller = TextEditingController(text: text)
      ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    final focus = FocusNode();
    setState(() {
      _cancelEdit();
      _editingChannel = ch;
      _editController = controller;
      _editFocus = focus;
    });
  }

  /// Discard the open edit. Called from setState contexts only.
  void _cancelEdit() {
    _editController?.dispose();
    _editFocus?.dispose();
    _editController = null;
    _editFocus = null;
    _editingChannel = null;
    _editError = null;
  }

  void _submitEdit(DisplayUnit unit) {
    final ch = _editingChannel;
    if (ch == null) return;
    final value = double.tryParse(_editController!.text);
    if (value == null || !value.isFinite) {
      setState(() => _editError = 'Enter a number');
      return;
    }
    hub.setTarePoint(
      ch,
      unit.rawFromGrossValue(hub.calibrationFor(ch), value)!,
    );
    setState(_cancelEdit);
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.settings.displayUnit.effective(
      resolveUnitAvailability(
        hub.calibrationFor,
        widget.settings.activeChannelIndices,
      ),
    );
    // The hub notifies per packet; the sheet rebuilds with it so the live
    // column actually reads live and a tare's completion shows in place.
    return ValueListenableBuilder<FeedHealth?>(
      valueListenable: widget.health,
      builder: (context, health, _) => ListenableBuilder(
        listenable: hub,
        builder: (context, _) {
          final channels = widget.settings.activeChannelIndices;
          final stale = hub.liveEdgeIsGap || (health?.noDataFlowing ?? false);
          final taring = hub.taring;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Tare',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  _headerRow(unit),
                  for (final ch in channels) _channelRow(ch, unit, stale),
                  if (channels.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('No active channels'),
                    ),
                  const Divider(height: 24),
                  _footer(taring),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _headerRow(DisplayUnit unit) {
    final captionStyle = Theme.of(context).textTheme.labelSmall;
    Widget cell(String text) =>
        Text(text, textAlign: TextAlign.end, style: captionStyle);
    return Row(
      children: [
        // The color-bar + name column; the unit caption sits there like
        // the stats table's "In X" overlay.
        const SizedBox(width: 12),
        Expanded(
          flex: 4,
          child: Text('In ${unit.symbol}', style: captionStyle),
        ),
        Expanded(flex: 3, child: cell('Live')),
        Expanded(flex: 3, child: cell('Tare point')),
        // Match the two icon buttons below so headers sit over the values.
        const SizedBox(width: 40),
        const SizedBox(width: 40),
      ],
    );
  }

  Widget _channelRow(int ch, DisplayUnit unit, bool stale) {
    final live = hub.currentValue(ch, unit);
    final staleColor = Theme.of(context).colorScheme.outline;
    const tabularFigures = [FontFeature.tabularFigures()];
    final valueStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFeatures: tabularFigures);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(width: 4, height: 28, color: getChannelColor(ch)),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: Text(
              widget.rig.channelTitles[ch],
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              live == null ? '—' : unit.formatValueOnly(live),
              textAlign: TextAlign.end,
              style: valueStyle?.copyWith(color: stale ? staleColor : null),
            ),
          ),
          Expanded(
            flex: 3,
            child: _tarePointCell(ch, unit, staleColor, valueStyle),
          ),
          SizedBox(
            width: 40,
            child: IconButton(
              tooltip: 'Tare this channel',
              onPressed: hub.taring ? null : () => hub.requestTare(channel: ch),
              icon: const Icon(Icons.exposure_zero, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ),
          SizedBox(
            width: 40,
            child: IconButton(
              tooltip: 'Reset this channel',
              onPressed: () => hub.resetTare(channel: ch),
              icon: const Icon(Icons.restart_alt, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  /// The tare point: plain right-aligned text, or the entry field while
  /// this channel is being edited. Tapping starts an absolute edit (the
  /// field IS the point where zero sits — see [showTareSheet]). It dims
  /// and refuses to open while a sampled tare fills its window — the
  /// coming commit owns the value.
  Widget _tarePointCell(
    int ch,
    DisplayUnit unit,
    Color staleColor,
    TextStyle? valueStyle,
  ) {
    if (_editingChannel == ch) {
      return TextField(
        autofocus: true,
        controller: _editController,
        focusNode: _editFocus,
        keyboardType: const TextInputType.numberWithOptions(
          signed: true,
          decimal: true,
        ),
        textAlign: TextAlign.end,
        style: valueStyle,
        decoration: InputDecoration(
          isDense: true,
          errorText: _editError,
          contentPadding: const EdgeInsets.symmetric(vertical: 4),
        ),
        onSubmitted: (_) => _submitEdit(unit),
        onTapOutside: (_) => setState(_cancelEdit),
      );
    }
    final point = hub.tarePoint(ch, unit);
    return GestureDetector(
      key: Key('tare-point-$ch'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _startEdit(ch, unit),
      child: Text(
        point == null ? '—' : unit.formatValueOnly(point),
        textAlign: TextAlign.end,
        style: valueStyle?.copyWith(color: hub.taring ? staleColor : null),
      ),
    );
  }

  Widget _footer(bool taring) {
    return Row(
      children: [
        TextButton(
          onPressed: hub.resetTare,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: const Text('Reset all'),
        ),
        const Spacer(),
        if (taring)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              'Taring…',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        FilledButton.tonal(
          onPressed: taring ? null : hub.requestTare,
          child: const Text('Tare all'),
        ),
      ],
    );
  }
}
