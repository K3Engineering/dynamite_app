import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/calibration.dart';
import '../services/ble_link_manager.dart';
import '../services/rig_state.dart';

/// Quick-pick values for the slot editor: the common nameplate numbers,
/// one tap away; anything else goes in the text field.
const quickCapacitiesKg = <double>[50, 100, 200, 500];
const quickSensitivitiesMvV = <double>[1, 2, 3];

/// Settings → Device settings → Load cells: the device's ten load cell
/// slots. The first four ARE the channels — the rail and the rotated CH
/// tags live in the static gutter left of the list, so they never travel
/// with a dragged row; the rest are spares carried on the device.
/// Assignment is a swap: drag a cell onto another slot and the two
/// exchange contents (a spare dragged into the top four goes on a channel,
/// the evicted cell takes the spare's place). Nothing else in the list
/// moves.
///
/// Edits and swaps take effect in this app immediately and raise the dirty
/// state of the status bar; nothing reaches the device until "Save to
/// device" (the flash doc is the rig's single truth — reads are automatic,
/// writes are explicit). The bar is ALWAYS present — clean state reads
/// "All settings saved to device." — so the list below never jumps when
/// the dirty state flips.
class RigSlotsSection extends StatefulWidget {
  const RigSlotsSection({super.key});

  @override
  State<RigSlotsSection> createState() => _RigSlotsSectionState();
}

/// Uniform row height: the channel gutter's labels align with the first
/// four rows by construction, so every row must be exactly this tall
/// (72 = a two-line ListTile's natural height).
const double _kRowHeight = 72;

/// Width of the static gutter holding the channel rail + CH tags.
const double _kGutterWidth = 28;

/// Height of the always-present status bar (fits the two buttons of the
/// dirty state with room to spare, so clean and dirty states are the same
/// height and the list never shifts).
const double _kBarHeight = 56;

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
    final rig = context.watch<RigState>();
    // The section reads the link only to gate the Save button: saving needs
    // the very device the flash doc came from to be connected.
    final connectedId = context.select<BleLinkManager, String>(
      (l) => l.connectedDeviceId,
    );

    if (!rig.hasDeviceDoc) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.phonelink_erase, color: Colors.grey),
          title: Text('No slot data from the device'),
          subtitle: Text(
            'Load cell slots are read from the device at connect time.',
          ),
        ),
      );
    }

    final slots = rig.effectiveSlots;
    final pending = rig.pending;
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
              final rowWidth = constraints.maxWidth - _kGutterWidth;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _ChannelGutter(),
                  Expanded(
                    child: Column(
                      children: [
                        for (int i = 0; i < kRigSlotCount; ++i)
                          _slotTile(context, rig, slots, i, rowWidth),
                      ],
                    ),
                  ),
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

  /// One slot row: a drop target for swaps, fixed height so the channel
  /// gutter aligns. Populated rows offer the drag handle; every row
  /// (including empty ones) accepts a drop.
  Widget _slotTile(
    BuildContext context,
    RigState rig,
    RigSlots slots,
    int i,
    double rowWidth,
  ) {
    final theme = Theme.of(context);
    final slot = slots[i];

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
        onTap: () => showAddToSlot(context, rig, i),
      );
    } else {
      final cell = slot.cell;
      final mtime = slot.mtime?.toLocal();
      final subtitle =
          cell.valuesLine +
          (mtime != null ? ' · saved ${mtime.month}/${mtime.day}' : '');
      tile = ListTile(
        title: Text(cell.title),
        subtitle: Text(subtitle),
        trailing: Draggable<int>(
          data: i,
          onDragStarted: () => setState(() => _dragIndex = i),
          onDragEnd: (_) => setState(() => _dragIndex = null),
          feedback: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: rowWidth,
              child: ListTile(
                title: Text(cell.title),
                subtitle: Text(subtitle),
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.drag_indicator, color: theme.colorScheme.outline),
          ),
        ),
        onTap: () => showSlotEditor(context, rig, i),
      );
    }

    return DragTarget<int>(
      // Dropping a row onto itself is not offered (and not highlighted).
      onWillAcceptWithDetails: (details) => details.data != i,
      onAcceptWithDetails: (details) => rig.swapSlots(details.data, i),
      builder: (context, candidateData, rejectedData) {
        final highlighted = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: _kRowHeight,
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

/// The static channel gutter: the teal rail spanning exactly the four
/// channel rows, with the rotated CH1–CH4 tags centered on each. A sibling
/// of the row list — not part of any row — so dragging a slot can never
/// move the channel markings.
class _ChannelGutter extends StatelessWidget {
  const _ChannelGutter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: _kGutterWidth,
      height: _kRowHeight * 4,
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
      ),
      child: Column(
        children: [
          for (int i = 0; i < 4; ++i)
            SizedBox(
              height: _kRowHeight,
              child: Center(
                child: RotatedBox(
                  quarterTurns: 3,
                  child: Text(
                    'CH ${i + 1}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The always-present save-state bar. Dirty: the red of the Live tab's
/// "Not connected" header (errorContainer), with content in the matching
/// on-color so it stays readable. Clean: a quiet confirmation. Both states
/// are exactly [_kBarHeight] tall, so toggling never moves the slot list.
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

    if (!dirty) {
      return Card(
        child: SizedBox(
          height: _kBarHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 18,
                  color: colors.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'All settings saved to device.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.outline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      color: colors.errorContainer,
      child: SizedBox(
        height: _kBarHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber,
                size: 18,
                color: colors.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Changes not saved to device — readings in this app '
                  'already use them.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onErrorContainer,
                  ),
                ),
              ),
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
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add-to-empty-slot dialog: the custom-entry form with last-seen cells below
// ---------------------------------------------------------------------------

/// The "+" sheet for an empty slot: the same editor as an edit, with the
/// cells this app has met before (on any device, or typed in) listed under
/// the form as one-tap alternatives, newest first. Either path fills the
/// slot as a pending edit.
Future<void> showAddToSlot(BuildContext context, RigState rig, int slot) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _SlotEditorDialog(rig: rig, slot: slot, includeHistory: true),
  );
}

String _slotTitle(int i) => i < 4 ? 'CH ${i + 1}' : 'Slot ${i + 1}';

// ---------------------------------------------------------------------------
// Slot editor dialog (edit a populated slot, or add to an empty one)
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
  const _SlotEditorDialog({
    required this.rig,
    required this.slot,
    this.includeHistory = false,
  });

  final RigState rig;
  final int slot;

  /// Add-to-empty-slot mode: the last-seen cells appear under the form as
  /// one-tap alternatives to typing values in (see [showAddToSlot]).
  final bool includeHistory;

  @override
  State<_SlotEditorDialog> createState() => _SlotEditorDialogState();
}

class _SlotEditorDialogState extends State<_SlotEditorDialog> {
  /// Last-seen cells offered in add mode: enough for quick reuse without
  /// burying the form.
  static const int _historyShown = 5;

  late final TextEditingController nameCtrl;
  late final TextEditingController capCtrl;
  late final TextEditingController sensCtrl;

  RigState get rig => widget.rig;
  int get slot => widget.slot;

  /// The cell being edited, or null when this is a new entry for an
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
      (double.tryParse(capCtrl.text.trim()) ?? 0) > 0 &&
      (double.tryParse(sensCtrl.text.trim()) ?? 0) > 0;

  void _save() {
    rig.setSlot(
      slot,
      LoadCellProfile(
        name: nameCtrl.text.trim(),
        capacityKg: double.parse(capCtrl.text.trim()),
        sensitivityMvV: double.parse(sensCtrl.text.trim()),
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
        '${editing ? 'Edit' : 'Add'} load cell — ${_slotTitle(slot)}',
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
              if (widget.includeHistory && rig.history.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  'Last seen in this app',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                for (final entry in rig.history.take(_historyShown))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.cell.title),
                    subtitle: Text(
                      '${entry.cell.valuesLine} · '
                      '${entry.lastSeen.month}/${entry.lastSeen.day}'
                      '${entry.deviceName.isNotEmpty ? ' on ${entry.deviceName}' : ''}',
                    ),
                    onTap: () {
                      rig.setSlot(slot, entry.cell);
                      Navigator.of(context).pop();
                    },
                  ),
              ],
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
