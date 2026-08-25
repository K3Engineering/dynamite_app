import 'package:material_ui/material_ui.dart';

import '../models/display_unit.dart';
import '../services/app_settings.dart';
import '../services/data_hub.dart';
import '../services/rig_state.dart';
import 'channel_palette.dart';

/// Per-channel tare control panel as a modal bottom sheet: each active
/// channel's tare offset (in the current display unit), with TARE/RESET
/// per channel and ALL variants in the footer. Actions act on the hub
/// directly and the sheet stays open, so the new offset is visible where
/// it was requested.
///
/// A tare offset cell doubles as manual entry: tap it to type the gross
/// point where zero sits — absolute, replacing the current offset
/// (`DataHub.setTareOffset`). Editing is unavailable while a sampled tare
/// fills its window.
///
/// An untared channel reads 0 — "no offset" is a first-class state (null
/// counts storage), so the column needs no special "untared" rendering.
Future<void> showTareSheet(
  BuildContext context, {
  required DataHub hub,
  required RigState rig,
  required AppSettings settings,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // So the in-sheet text field pushes the sheet above the keyboard.
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _TareSheet(hub: hub, rig: rig, settings: settings),
    ),
  );
}

class _TareSheet extends StatefulWidget {
  final DataHub hub;
  final RigState rig;
  final AppSettings settings;

  const _TareSheet({
    required this.hub,
    required this.rig,
    required this.settings,
  });

  @override
  State<_TareSheet> createState() => _TareSheetState();
}

class _TareSheetState extends State<_TareSheet> {
  /// Channel whose tare offset is being typed, or null when no edit is
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
    final current = hub.tareOffset(ch, unit);
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
    hub.setTareOffset(
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
    // The hub notifies per packet; the sheet rebuilds with it so a tare's
    // completion shows in place.
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final channels = widget.settings.activeChannelIndices;
        final taring = hub.taring;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _topBar(),
                _titleRow(unit),
                _headerRow(),
                for (final ch in channels) _channelRow(ch, unit),
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
    );
  }

  /// The drag-handle row: the dismiss pill centered (showModalBottomSheet's
  /// own showDragHandle can't host the close affordance) with the close
  /// button at the row's right end. The height is pinned to the handle
  /// zone, so the button's optical center is the pill's centerline by
  /// construction, not by coincidence of widget sizes.
  Widget _topBar() {
    return SizedBox(
      height: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withAlpha(0x66),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              height: 24,
              child: IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _titleRow(DisplayUnit unit) {
    final theme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text('Tare', style: theme.titleLarge),
        const SizedBox(width: 6),
        Text('(${unit.symbol})', style: theme.labelSmall),
      ],
    );
  }

  Widget _headerRow() {
    final captionStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600);
    return Row(
      children: [
        // The color-bar + gap prefix of a channel row.
        const SizedBox(width: 12),
        Expanded(flex: 4, child: Text('Name', style: captionStyle)),
        Expanded(
          flex: 3,
          child: Text(
            'Tare offset',
            textAlign: TextAlign.end,
            style: captionStyle,
          ),
        ),
        // Match the gap + two buttons below so headers sit over the values.
        const SizedBox(width: 12),
        const SizedBox(width: 48),
        const SizedBox(width: 48),
      ],
    );
  }

  Widget _channelRow(int ch, DisplayUnit unit) {
    const tabularFigures = [FontFeature.tabularFigures()];
    final valueStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontFeatures: tabularFigures);
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
          Expanded(flex: 3, child: _tareOffsetCell(ch, unit, valueStyle)),
          const SizedBox(width: 12),
          SizedBox(
            width: 48,
            child: IconButton.filledTonal(
              tooltip: 'Tare this channel',
              onPressed: hub.taring ? null : () => hub.requestTare(channel: ch),
              icon: const Icon(Icons.exposure_zero, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ),
          SizedBox(
            width: 48,
            // The app's destructive pairing (see dialogs.dart): contrast
            // comes from the scheme, not a raw primary-tint glyph.
            child: IconButton.filled(
              tooltip: 'Reset this channel',
              onPressed: () => hub.resetTare(channel: ch),
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
                foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
              ),
              icon: const Icon(Icons.restart_alt, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  /// The tare offset: plain right-aligned text, or the entry field while
  /// this channel is being edited. Tapping starts an absolute edit (the
  /// field IS the point where zero sits — see [showTareSheet]). It dims
  /// and refuses to open while a sampled tare fills its window — the
  /// coming commit owns the value.
  Widget _tareOffsetCell(int ch, DisplayUnit unit, TextStyle? valueStyle) {
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
    final offset = hub.tareOffset(ch, unit);
    return GestureDetector(
      key: Key('tare-offset-$ch'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _startEdit(ch, unit),
      child: Text(
        offset == null ? '—' : unit.formatValueOnly(offset),
        textAlign: TextAlign.end,
        style: valueStyle?.copyWith(
          color: hub.taring ? Theme.of(context).colorScheme.outline : null,
        ),
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
