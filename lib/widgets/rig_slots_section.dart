import 'package:material_ui/material_ui.dart';

import '../models/load_cell.dart';
import '../models/rig_edits.dart';
import '../utils/format.dart';

/// Quick-pick values for the slot editor: the common nameplate numbers,
/// one tap away; anything else goes in the text field.
const quickCapacitiesKg = <double>[50, 100, 200, 500];
const quickSensitivitiesMvV = <double>[1, 2, 3];

/// The device's ten load cell slots: the first four ARE the channels, the
/// rest are spares carried on the device. Assignment is a swap — drag a
/// cell onto another slot and the two exchange contents.
///
/// Edits take effect in this app immediately; nothing reaches the device
/// until "Save to device" (the flash doc is the rig's single truth —
/// reads are automatic, writes are explicit).
///
/// Dumb: the rig slices and the mutation callbacks are handed in by the
/// caller (the Settings tab wires them to `RigState`).
class RigSlotsSection extends StatefulWidget {
  const RigSlotsSection({
    super.key,
    required this.connectedDeviceId,
    required this.hasDeviceDoc,
    required this.slots,
    required this.pending,
    required this.history,
    required this.onSave,
    required this.onRevert,
    required this.onSwapSlots,
    required this.onSetSlot,
    required this.onClearSlot,
  });

  /// The currently connected device ('' when none): gates the Save button —
  /// saving needs the very device the flash doc came from to be connected.
  final String connectedDeviceId;

  /// Whether a flash document has been read this run; without one the
  /// section renders its placeholder.
  final bool hasDeviceDoc;

  /// The slot list to render (the rig's effective slots: pending edits when
  /// dirty, else the device's flash state).
  final RigSlots slots;

  /// The unsaved-edit session, or null when clean.
  final PendingRigEdits? pending;

  /// Cells this app has met before, newest first (the add dialog's quick
  /// picks).
  final List<RigHistoryEntry> history;

  /// Write the edited slots to the device; false means the write or its
  /// verification failed (changes are kept).
  final Future<bool> Function() onSave;

  /// Discard the pending edits.
  final VoidCallback onRevert;

  /// Exchange two slots' contents.
  final void Function(int a, int b) onSwapSlots;

  /// Place a cell into a slot (add or edit).
  final void Function(int slot, LoadCellProfile cell) onSetSlot;

  /// Empty a slot.
  final void Function(int slot) onClearSlot;

  @override
  State<RigSlotsSection> createState() => _RigSlotsSectionState();
}

/// Uniform row height: the channel gutter's labels align with the first
/// four rows by construction, so every row must be exactly this tall
/// (72 = a two-line ListTile's natural height).
const double _kRowHeight = 72;

/// Width of the static gutter holding the channel rail + CH tags.
const double _kGutterWidth = 28;

class _RigSlotsSectionState extends State<RigSlotsSection> {
  bool _saving = false;

  /// Slot index currently being dragged (dims its source row), or null.
  int? _dragIndex;

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await widget.onSave();
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
    if (!widget.hasDeviceDoc) {
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
    final slots = widget.slots;
    final pending = widget.pending;
    final connectedId = widget.connectedDeviceId;

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
          onRevert: widget.onRevert,
          onSave: _save,
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The gutter's top padding matches the card's default margin,
            // so the tags stay centered on the four channel rows.
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: _ChannelGutter(),
            ),
            Expanded(
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final rowWidth = constraints.maxWidth;
                    return Column(
                      children: [
                        for (int i = 0; i < kRigSlotCount; ++i)
                          _slotTile(context, slots, i, rowWidth),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
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
  /// gutter aligns. The drag is vertical-only:
  /// [Draggable.axis] pins the feedback — a full-width replica of the row
  /// — to the row's X for the whole drag, so it slides straight up and
  /// down the list instead of following the pointer sideways.
  ///
  /// All edit affordances (tap, drag start, drop) close while a save is in
  /// flight: an edit landing mid-write would mutate the pending session the
  /// save already snapshotted (see RigState.saveToDevice's state guard).
  Widget _slotTile(
    BuildContext context,
    RigSlots slots,
    int i,
    double rowWidth,
  ) {
    final theme = Theme.of(context);
    final slot = slots[i];

    return DragTarget<int>(
      // Dropping a row onto itself is not offered (and not highlighted).
      onWillAcceptWithDetails: (details) => !_saving && details.data != i,
      onAcceptWithDetails: (details) => widget.onSwapSlots(details.data, i),
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
            onTap: _saving
                ? null
                : () => showAddToSlot(
                    context,
                    slot: i,
                    history: widget.history,
                    onSetSlot: widget.onSetSlot,
                    onClearSlot: widget.onClearSlot,
                  ),
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
                  width: rowWidth,
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
            onTap: _saving
                ? null
                : () => showSlotEditor(
                    context,
                    slot: i,
                    initial: cell,
                    onSetSlot: widget.onSetSlot,
                    onClearSlot: widget.onClearSlot,
                  ),
          );
        }

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

/// The static channel gutter. Sits outside the card so the channel
/// markings annotate the list without being part of any row, and dragging
/// a slot can never move them.
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
          right: BorderSide(color: theme.colorScheme.primary, width: 3),
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
Future<void> showAddToSlot(
  BuildContext context, {
  required int slot,
  required List<RigHistoryEntry> history,
  required void Function(int slot, LoadCellProfile cell) onSetSlot,
  required void Function(int slot) onClearSlot,
}) {
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
              if (history.isNotEmpty) ...[
                Text(
                  'Last seen in this app',
                  style: Theme.of(ctx).textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                for (final entry in history)
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
                      onSetSlot(slot, entry.cell);
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
                  Navigator.of(ctx).pop();
                  await showSlotEditor(
                    context,
                    slot: slot,
                    initial: null,
                    onSetSlot: onSetSlot,
                    onClearSlot: onClearSlot,
                  );
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

/// Edit slot [slot]'s cell ([initial]; null to create one for an empty
/// slot). Saving writes a PENDING edit — it reaches the device only via
/// "Save to device".
Future<void> showSlotEditor(
  BuildContext context, {
  required int slot,
  required LoadCellProfile? initial,
  required void Function(int slot, LoadCellProfile cell) onSetSlot,
  required void Function(int slot) onClearSlot,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SlotEditorDialog(
      slot: slot,
      initial: initial,
      onSetSlot: onSetSlot,
      onClearSlot: onClearSlot,
    ),
  );
}

/// The editor dialog as a stateful widget: the text controllers live in the
/// [State], so they're disposed only when the route's pop animation finally
/// unmounts the dialog.
class _SlotEditorDialog extends StatefulWidget {
  const _SlotEditorDialog({
    required this.slot,
    required this.initial,
    required this.onSetSlot,
    required this.onClearSlot,
  });

  final int slot;

  /// The cell being edited, or null when this is a custom entry for an
  /// empty slot.
  final LoadCellProfile? initial;

  final void Function(int slot, LoadCellProfile cell) onSetSlot;
  final void Function(int slot) onClearSlot;

  @override
  State<_SlotEditorDialog> createState() => _SlotEditorDialogState();
}

class _SlotEditorDialogState extends State<_SlotEditorDialog> {
  late final TextEditingController nameCtrl;
  late final TextEditingController capCtrl;
  late final TextEditingController sensCtrl;

  int get slot => widget.slot;

  @override
  void initState() {
    super.initState();
    final cell = widget.initial;
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
    widget.onSetSlot(
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
    widget.onClearSlot(slot);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
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
