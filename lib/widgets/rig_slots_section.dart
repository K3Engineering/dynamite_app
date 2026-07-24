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
/// slots. The first four ARE the channels (marked with the rotated CH tags
/// and the rail on the left edge); the rest are spares carried on the
/// device. Reordering is the assignment gesture: drag a cell into the top
/// four to put it on a channel.
///
/// Edits and moves take effect in this app immediately and raise the dirty
/// banner; nothing reaches the device until "Save to device" (the flash doc
/// is the rig's single truth — reads are automatic, writes are explicit).
class RigSlotsSection extends StatefulWidget {
  const RigSlotsSection({super.key});

  @override
  State<RigSlotsSection> createState() => _RigSlotsSectionState();
}

class _RigSlotsSectionState extends State<RigSlotsSection> {
  bool _saving = false;

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
        if (pending != null) ...[
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Changes not saved to device — readings in this app '
                      'already use them.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: _saving ? null : rig.revert,
                    child: const Text('Revert'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: canSave ? () => _save(rig) : null,
                    child: Text(_saving ? 'Saving…' : 'Save to device'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Card(
          clipBehavior: Clip.antiAlias,
          child: ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            // onReorderItem reports remove-then-insert indices already
            // (no manual newIndex adjustment).
            onReorderItem: rig.moveSlot,
            children: [
              for (int i = 0; i < kRigSlotCount; ++i)
                _slotRow(context, rig, slots, i, key: ValueKey('slot-$i')),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'The top four slots are the channels — drag a cell up to put it on '
          'a channel, drag it out to unassign.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }

  Widget _slotRow(
    BuildContext context,
    RigState rig,
    RigSlots slots,
    int i, {
    required Key key,
  }) {
    final theme = Theme.of(context);
    final isChannel = i < 4;
    final slot = slots[i];

    // The rail: a continuous left border on the four channel rows (they are
    // direct siblings, no card gaps) — the 80's-stereo bracket grouping them
    // as "the rig", with the rotated CH tag inside each row.
    final railDecoration = isChannel
        ? BoxDecoration(
            border: Border(
              left: BorderSide(color: theme.colorScheme.primary, width: 3),
            ),
          )
        : null;

    final Widget content;
    if (slot == null) {
      content = ListTile(
        leading: isChannel ? _channelTag(theme, i) : null,
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
      content = ListTile(
        leading: isChannel ? _channelTag(theme, i) : null,
        title: Text(cell.title),
        subtitle: Text(
          cell.valuesLine +
              (mtime != null ? ' · saved ${mtime.month}/${mtime.day}' : ''),
        ),
        trailing: ReorderableDragStartListener(
          index: i,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.drag_indicator, color: theme.colorScheme.outline),
          ),
        ),
        onTap: () => showSlotEditor(context, rig, i),
      );
    }

    return Container(key: key, decoration: railDecoration, child: content);
  }

  /// The rotated channel tag inside the rail (CH1..CH4).
  static Widget _channelTag(ThemeData theme, int i) => RotatedBox(
    quarterTurns: 3,
    child: Text(
      'CH ${i + 1}',
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
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
      title: Text('Add load cell — ${_slotTitle(slot)}'),
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
                    subtitle: Text(
                      '${entry.cell.valuesLine} · '
                      '${entry.lastSeen.month}/${entry.lastSeen.day}'
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

String _slotTitle(int i) => i < 4 ? 'CH ${i + 1}' : 'Slot ${i + 1}';

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
  late final TextEditingController spanCtrl;

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
    spanCtrl = TextEditingController(text: _num(cell?.span ?? 1.0));
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    capCtrl.dispose();
    sensCtrl.dispose();
    spanCtrl.dispose();
    super.dispose();
  }

  bool _valid() =>
      (double.tryParse(capCtrl.text.trim()) ?? 0) > 0 &&
      (double.tryParse(sensCtrl.text.trim()) ?? 0) > 0 &&
      (double.tryParse(spanCtrl.text.trim()) ?? 0) > 0;

  void _save() {
    rig.setSlot(
      slot,
      LoadCellProfile(
        name: nameCtrl.text.trim(),
        capacityKg: double.parse(capCtrl.text.trim()),
        sensitivityMvV: double.parse(sensCtrl.text.trim()),
        span: double.parse(spanCtrl.text.trim()),
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
        '${editing ? 'Edit' : 'New'} load cell — ${_slotTitle(slot)}',
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
              const SizedBox(height: 12),
              TextField(
                controller: spanCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Span factor',
                  hintText: '1.0',
                ),
                onChanged: (_) => setState(() {}),
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
