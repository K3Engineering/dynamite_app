import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/calibration.dart';
import '../services/adc_protocol.dart';
import '../services/ble_link_manager.dart';
import '../services/rig_state.dart';
import '../utils/format.dart';

/// Quick-pick values for the slot editor: the common nameplate numbers,
/// one tap away; anything else goes in the text field.
const quickCapacitiesKg = <double>[50, 100, 200, 500];
const quickSensitivitiesMvV = <double>[1, 2, 3];

/// Settings → Device settings → Load cells: the device's ten load cell
/// slots. The first [nwNumAdcChan] ARE the channels — each carries its CH
/// tag in a narrow rail cell next to its own row, height-matched by the
/// layout (never by a fixed constant), so the tags annotate position and
/// can never travel with a dragged row; the rest are spares carried on the
/// device.
/// Assignment is a swap: drag a cell onto another slot and the two
/// exchange contents (a spare dragged into the top four goes on a channel,
/// the evicted cell takes the spare's place). Nothing else in the list
/// moves.
///
/// Edits and swaps take effect in this app immediately and raise the dirty
/// state of the status bar; nothing reaches the device until "Save to
/// device" (the flash doc is the rig's single truth — reads are automatic,
/// writes are explicit). The bar is ALWAYS present — the clean state reads
/// "Settings shown are read from the device." — so the list below never
/// jumps when the dirty state flips.
class RigSlotsSection extends StatefulWidget {
  const RigSlotsSection({super.key});

  @override
  State<RigSlotsSection> createState() => _RigSlotsSectionState();
}

/// Width of the per-row channel tag cell (rail + rotated CH tag). Spare
/// rows get a same-width spacer so every tile in the list aligns.
const double _kGutterWidth = 28;

class _RigSlotsSectionState extends State<RigSlotsSection> {
  bool _saving = false;

  /// Slot index currently being dragged (dims its source row), or null.
  int? _dragIndex;

  Future<void> _save(RigState rig) async {
    setState(() => _saving = true);
    final ok = await rig.saveToDevice();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Load cells saved to device.'
              : 'Could not write to the device — changes kept.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Narrow selects: the section renders three slices of the rig (doc
    // presence, the slots, the dirty state), not every RigState notify.
    final hasDoc = context.select<RigState, bool>((r) => r.hasDeviceDoc);
    if (!hasDoc) {
      // The dim "nothing here" affordance: the theme's outline role, as in
      // EmptyPlaceholder — not a raw Material grey.
      return Card(
        child: ListTile(
          leading: Icon(
            Icons.phonelink_erase,
            color: Theme.of(context).colorScheme.outline,
          ),
          title: const Text('No slot data from the device'),
          subtitle: const Text(
            'Load cell slots are read from the device at connect time.',
          ),
        ),
      );
    }
    final slots = context.select<RigState, RigSlots>((r) => r.effectiveSlots);
    final pending = context.select<RigState, PendingRigEdits?>(
      (r) => r.pending,
    );
    final rig = context.read<RigState>();
    // The section reads the link only to gate the Save button: saving needs
    // the very device the flash doc came from to be connected.
    final connectedId = context.select<BleLinkManager, String>(
      (l) => l.connectedDeviceId,
    );

    final canSave =
        pending != null &&
        connectedId.isNotEmpty &&
        connectedId == pending.deviceId &&
        !_saving;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusBar(
          dirty: pending != null,
          saving: _saving,
          canSave: canSave,
          onRevert: rig.revert,
          onSave: () => _save(rig),
        ),
        const SizedBox(height: 8),
        Card(
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // The tiles sit right of the tag column; the drag feedback
              // replica is sized to the tile, not the whole card.
              final tileWidth = constraints.maxWidth - _kGutterWidth;
              return Column(
                children: [
                  for (int i = 0; i < kRigSlotCount; ++i)
                    _slotRow(context, rig, slots, i, tileWidth),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'The top four slots are the channels — drag a cell onto another '
          'slot to swap them; swap a spare into the top four to put it on '
          'a channel.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }

  /// One slot row: the channel tag cell (channel rows) or a same-width
  /// spacer (spares), then the tile itself. IntrinsicHeight lets the tag
  /// cell match its OWN row's height — the framework keeps tag and row
  /// aligned at any text scale, so no fixed row height is needed anywhere.
  /// (Two layout passes are nothing for a static ten-row list.)
  Widget _slotRow(
    BuildContext context,
    RigState rig,
    RigSlots slots,
    int i,
    double tileWidth,
  ) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (i < nwNumAdcChan)
            _ChannelTagCell(index: i)
          else
            const SizedBox(width: _kGutterWidth),
          Expanded(child: _slotTile(context, rig, slots, i, tileWidth)),
        ],
      ),
    );
  }

  /// One slot row's tile: a drop target for swaps. Populated rows offer a
  /// drag handle; every row (including empty ones) accepts a drop. The
  /// drag is vertical-only: [Draggable.axis] pins the feedback — a
  /// replica of the tile, sized to [tileWidth] — to the row's X for the
  /// whole drag, so it slides straight up and down the list instead of
  /// following the pointer sideways.
  ///
  /// All edit affordances (tap, drag start, drop) close while a save is in
  /// flight: an edit landing mid-write would mutate the pending session the
  /// save already snapshotted (see RigState.saveToDevice's state guard).
  ///
  /// TODO: also start the drag on a long-press anywhere on the row — the
  /// touch-platform pattern in ReorderableListView — while keeping the
  /// handle for immediate dragging on desktop.
  Widget _slotTile(
    BuildContext context,
    RigState rig,
    RigSlots slots,
    int i,
    double tileWidth,
  ) {
    final theme = Theme.of(context);
    final slot = slots[i];

    return DragTarget<int>(
      // Dropping a row onto itself is not offered (and not highlighted).
      onWillAcceptWithDetails: (details) => !_saving && details.data != i,
      onAcceptWithDetails: (details) => rig.swapSlots(details.data, i),
      // The tile is built inside the builder so the drag feedback can be
      // anchored to this row's render box (rowContext).
      builder: (rowContext, candidateData, rejectedData) {
        final highlighted = candidateData.isNotEmpty;

        final Widget tile;
        if (slot == null) {
          tile = ListTile(
            title: Text(
              'Empty slot',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            subtitle: const Text('Tap to add a load cell'),
            trailing: Icon(
              Icons.add_circle_outline,
              color: theme.colorScheme.outline,
            ),
            onTap: _saving ? null : () => showAddToSlot(context, rig, i),
          );
        } else {
          final cell = slot.cell;
          final mtime = slot.mtime?.toLocal();
          // Date only: the mtime answers "how old is this calibration" — a
          // months/years question, so the time of day would be noise.
          final subtitle =
              cell.valuesLine +
              (mtime != null ? ' · saved ${formatDate(mtime)}' : '');
          tile = ListTile(
            title: Text(cell.title),
            subtitle: Text(subtitle),
            trailing: Draggable<int>(
              data: i,
              axis: Axis.vertical,
              maxSimultaneousDrags: _saving ? 0 : 1,
              // Anchor the feedback to the row, not the handle: the
              // default childDragAnchorStrategy would pin the feedback's
              // X to the handle's left edge, hanging the full-width row
              // replica off the side of the list.
              dragAnchorStrategy: (draggable, handleContext, position) {
                final rowBox = rowContext.findRenderObject()! as RenderBox;
                return position - rowBox.localToGlobal(Offset.zero);
              },
              onDragStarted: () => setState(() => _dragIndex = i),
              onDragEnd: (_) => setState(() => _dragIndex = null),
              feedback: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: tileWidth,
                  child: ListTile(
                    title: Text(cell.title),
                    subtitle: Text(subtitle),
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Icons.drag_indicator,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            onTap: _saving ? null : () => showSlotEditor(context, rig, i),
          );
        }

        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: highlighted
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : null,
            border: highlighted
                ? Border.all(color: theme.colorScheme.primary, width: 1.5)
                : null,
          ),
          child: Opacity(opacity: _dragIndex == i ? 0.35 : 1.0, child: tile),
        );
      },
    );
  }
}

/// One channel row's tag cell: the rotated CH tag centered in it, the teal
/// rail as its right border (contiguous cells stack into one rail spanning
/// the channel rows). Stretched to its own row's height by the enclosing
/// IntrinsicHeight — alignment comes from the layout, not a shared
/// constant. Sits OUTSIDE the row's Draggable/drop target, so it can
/// never travel with a drag.
class _ChannelTagCell extends StatelessWidget {
  const _ChannelTagCell({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: _kGutterWidth,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
      ),
      child: Center(
        child: RotatedBox(
          quarterTurns: 3,
          child: Text(
            'CH ${index + 1}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

/// The always-present save-state bar. Dirty: the red of the Live tab's
/// "Not connected" header (errorContainer), with content in the matching
/// on-color so it stays readable. Clean: a quiet confirmation. One layout
/// for both states — the buttons keep their space while hidden, so the bar
/// (and the slot list below) never moves when the dirty state flips.
class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.dirty,
    required this.saving,
    required this.canSave,
    required this.onRevert,
    required this.onSave,
  });

  final bool dirty;
  final bool saving;
  final bool canSave;
  final VoidCallback onRevert;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fg = dirty ? colors.onErrorContainer : colors.outline;

    return Card(
      color: dirty ? colors.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(
              dirty ? Icons.warning_amber : Icons.check_circle_outline,
              size: 18,
              color: fg,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                dirty
                    ? 'Changes not saved to device — readings in this app '
                          'already use them.'
                    // Provenance, not a success claim: the clean state also
                    // covers a revert and a stale-edit discard, where "saved"
                    // would be a lie.
                    : 'Settings shown are read from the device.',
                style: theme.textTheme.bodySmall?.copyWith(color: fg),
              ),
            ),
            Visibility(
              visible: dirty,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: Row(
                children: [
                  TextButton(
                    onPressed: saving ? null : onRevert,
                    style: TextButton.styleFrom(
                      foregroundColor: colors.onErrorContainer,
                    ),
                    child: const Text('Revert'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: canSave ? onSave : null,
                    child: Text(saving ? 'Saving…' : 'Save to device'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add-to-empty-slot dialog: last-seen values, or a custom entry
// ---------------------------------------------------------------------------

/// The "+" sheet for an empty slot: cells this app has met before (on any
/// device, or typed in), newest first; a custom entry goes through the same
/// editor as an edit. Picking either fills the slot as a pending edit.
Future<void> showAddToSlot(BuildContext context, RigState rig, int slot) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Add load cell — ${rigSlotTitle(slot)}'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (rig.history.isNotEmpty) ...[
                Text(
                  'Last seen in this app',
                  style: Theme.of(ctx).textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                for (final entry in rig.history)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.cell.title),
                    // Date + time: bench work swaps several cells within one
                    // day, and a date alone can't tell morning from
                    // afternoon.
                    subtitle: Text(
                      '${entry.cell.valuesLine} · '
                      '${formatTimestamp(entry.lastSeen)}'
                      '${entry.deviceName.isNotEmpty ? ' on ${entry.deviceName}' : ''}',
                    ),
                    onTap: () {
                      rig.setSlot(slot, entry.cell);
                      Navigator.of(ctx).pop();
                    },
                  ),
                const Divider(),
              ] else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Cells you connect or type in will show up here for '
                    'quick reuse.',
                  ),
                ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.tune),
                title: const Text('Custom entry…'),
                onTap: () async {
                  // Replace this dialog with the editor; a save there fills
                  // the same slot.
                  Navigator.of(ctx).pop();
                  await showSlotEditor(context, rig, slot);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Slot editor dialog (edit a populated slot, or custom entry for an empty one)
// ---------------------------------------------------------------------------

/// Edit slot [slot]'s cell (or create it, when the slot is empty). Saving
/// writes a PENDING edit — it reaches the device only via "Save to device".
Future<void> showSlotEditor(BuildContext context, RigState rig, int slot) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SlotEditorDialog(rig: rig, slot: slot),
  );
}

/// The editor dialog as a stateful widget: the text controllers live in the
/// [State], so they're disposed only when the route's pop animation finally
/// unmounts the dialog.
class _SlotEditorDialog extends StatefulWidget {
  const _SlotEditorDialog({required this.rig, required this.slot});

  final RigState rig;
  final int slot;

  @override
  State<_SlotEditorDialog> createState() => _SlotEditorDialogState();
}

class _SlotEditorDialogState extends State<_SlotEditorDialog> {
  late final TextEditingController nameCtrl;
  late final TextEditingController capCtrl;
  late final TextEditingController sensCtrl;

  RigState get rig => widget.rig;
  int get slot => widget.slot;

  /// The cell being edited, or null when this is a custom entry for an
  /// empty slot.
  LoadCellProfile? get initial => rig.effectiveSlots.cellAt(slot);

  @override
  void initState() {
    super.initState();
    final cell = initial;
    nameCtrl = TextEditingController(text: cell?.name ?? '');
    capCtrl = TextEditingController(
      text: cell != null ? _num(cell.capacityKg) : '',
    );
    sensCtrl = TextEditingController(
      text: cell != null ? _num(cell.sensitivityMvV) : '',
    );
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    capCtrl.dispose();
    sensCtrl.dispose();
    super.dispose();
  }

  bool _valid() =>
      (_typedNumber(capCtrl.text) ?? 0) > 0 &&
      (_typedNumber(sensCtrl.text) ?? 0) > 0;

  void _save() {
    final cap = _typedNumber(capCtrl.text);
    final sens = _typedNumber(sensCtrl.text);
    // The Save button is gated on [_valid], so both parse positive here.
    if (cap == null || sens == null || cap <= 0 || sens <= 0) return;
    rig.setSlot(
      slot,
      LoadCellProfile(
        name: nameCtrl.text.trim(),
        capacityKg: cap,
        sensitivityMvV: sens,
      ),
    );
    Navigator.of(context).pop();
  }

  void _clear() {
    rig.clearSlot(slot);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final editing = initial != null;
    return AlertDialog(
      title: Text(
        '${editing ? 'Edit' : 'New'} load cell — ${rigSlotTitle(slot)}',
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Name (optional)',
                  hintText: 'e.g. Golden cell',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: capCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Capacity (kg)'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in quickCapacitiesKg)
                    ActionChip(
                      label: Text('${_num(v)} kg'),
                      onPressed: () => setState(() => capCtrl.text = _num(v)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: sensCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Sensitivity (mV/V at full scale)',
                  hintText: 'Exact value from the cal cert, e.g. 2.007',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in quickSensitivitiesMvV)
                    ActionChip(
                      label: Text('${_num(v)} mV/V'),
                      onPressed: () => setState(() => sensCtrl.text = _num(v)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (editing)
          TextButton(
            onPressed: _clear,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Clear slot'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid() ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Render a double without a trailing '.0' for whole numbers.
String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Parse a typed-in number, tolerating a comma decimal separator (some
/// locales' decimal key inserts one). A single comma with no '.' is treated
/// as a decimal separator — that reads the cal-cert example "2,007"
/// correctly as 2.007, at the cost of reading thousands-grouped "1,000" as
/// 1.0 (an accepted ambiguity in the decimal-comma direction; inputs with
/// several commas, or both separators, fail to parse rather than misparse).
double? _typedNumber(String s) {
  final t = s.trim();
  if (!t.contains('.') && t.indexOf(',') == t.lastIndexOf(',')) {
    return double.tryParse(t.replaceFirst(',', '.'));
  }
  return double.tryParse(t);
}
