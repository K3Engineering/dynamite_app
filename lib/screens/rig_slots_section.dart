import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';

import '../models/device_profile.dart';
import '../models/load_cell.dart';
import '../services/rig_state.dart';
import '../utils/format.dart';
import '../widgets/snackbars.dart';

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
/// reads are automatic, writes are explicit). Both the document and
/// unsaved edits die with the link, so a connected session is the only
/// context this section ever renders: the parent mounts it only while a
/// device is connected, and a mid-session drop clears the rig under it.
class RigSlotsSection extends StatefulWidget {
  const RigSlotsSection({super.key, required this.rig});

  /// The rig's slot state. Passed in (not reached through Provider) so this
  /// section renders without an app-wide provider above it.
  final RigState rig;

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
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Load cells saved to device.')),
      );
    } else {
      showErrorSnackBar(
        ScaffoldMessenger.of(context),
        'Could not write to the device — changes kept.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // The section rebuilds on any RigState notify: the rig changes only on
    // edits/reads, so a 10-row rebuild is free and keeps the section's
    // dependency a plain constructor parameter.
    return ListenableBuilder(
      listenable: widget.rig,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final rig = widget.rig;
    if (!rig.hasDeviceDoc) {
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
    final slots = rig.effectiveSlots;
    final dirty = rig.hasPending;

    // Dirty implies connected: both the document and pending edits die
    // with the link (see RigState), and the parent unmounts this section
    // once no device is connected.
    final canSave = dirty && !_saving;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusBar(
          dirty: dirty,
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
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// One slot row: the channel tag cell (channel rows) or a same-width
  /// spacer (spares), then the tile itself. IntrinsicHeight lets the tag
  /// cell match its OWN row's height — the framework keeps tag and row
  /// aligned at any text scale, so no fixed row height is needed anywhere.
  /// (Two layout passes should be cheap for a static ten-row list.)
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
          if (i < kAdcChannelCount)
            _ChannelTagCell(index: i)
          else
            const SizedBox(width: _kGutterWidth),
          Expanded(child: _slotTile(context, rig, slots, i, tileWidth)),
        ],
      ),
    );
  }

  /// One slot row's tile: a drop target for swaps. The drag is
  /// vertical-only: [Draggable.axis] pins the feedback — a replica of the
  /// tile, sized to [tileWidth] — to the row's X for the whole drag, so it
  /// slides straight up and down the list instead of following the pointer
  /// sideways.
  ///
  /// The whole row is the drag source; how a drag starts depends on the
  /// platform. Touch platforms require a tap-and-hold so a swipe still
  /// scrolls; desktops start dragging on mouse-down (the recognizer claims
  /// the gesture only past the 1 px precise-pointer slop, so taps still
  /// open the editor). On web the reported platform is the browser's OS,
  /// which puts phone browsers (Android Chrome, Bluefy on iOS) on the
  /// tap-and-hold path.
  ///
  /// All edit affordances (tap, drag start, drop) close while a save is in
  /// flight: an edit landing mid-write would mutate the pending session the
  /// save already snapshotted (see RigState.saveToDevice's state guard).
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
      builder: (context, candidateData, rejectedData) {
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
          final subtitle = cell.valuesLine;
          final feedback = Material(
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
          );
          final row = ListTile(
            title: Text(cell.title),
            subtitle: Text(subtitle),
            trailing: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.drag_indicator,
                color: theme.colorScheme.outline,
              ),
            ),
            onTap: _saving ? null : () => showSlotEditor(context, rig, i),
          );
          tile = switch (defaultTargetPlatform) {
            TargetPlatform.android ||
            TargetPlatform.iOS ||
            TargetPlatform.fuchsia => LongPressDraggable<int>(
              data: i,
              axis: Axis.vertical,
              maxSimultaneousDrags: _saving ? 0 : 1,
              onDragStarted: () => setState(() => _dragIndex = i),
              onDragEnd: (_) => setState(() => _dragIndex = null),
              feedback: feedback,
              child: row,
            ),
            _ => Draggable<int>(
              data: i,
              axis: Axis.vertical,
              maxSimultaneousDrags: _saving ? 0 : 1,
              onDragStarted: () => setState(() => _dragIndex = i),
              onDragEnd: (_) => setState(() => _dragIndex = null),
              feedback: feedback,
              child: row,
            ),
          };
        }

        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: highlighted
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : null,
          ),
          // The highlight border lives in the FOREGROUND decoration: a
          // border in `decoration` becomes real layout padding and would
          // grow the highlighted row, jittering the list as the hover
          // moves; the foreground paint does not affect layout. (Always a
          // BoxDecoration — never null — so the border keeps its 120ms
          // fade in both directions.)
          foregroundDecoration: BoxDecoration(
            border: highlighted
                ? Border.all(color: theme.colorScheme.primary, width: 1.5)
                : null,
          ),
          // A transparent Material between the tinted DecoratedBox and the
          // tile: the ListTile paints its ink splash on its nearest
          // Material ancestor, so without this the splash lands on the
          // Card BELOW the highlight tint (and trips ListTile's debug
          // check for exactly that).
          child: Material(
            type: MaterialType.transparency,
            child: Opacity(opacity: _dragIndex == i ? 0.35 : 1.0, child: tile),
          ),
        );
      },
    );
  }
}

/// One channel row's tag cell: the rotated CH tag centered in it, the
/// primary-color rail as its right border (contiguous cells stack into one
/// rail spanning the channel rows). Stretched to its own row's height by
/// the enclosing IntrinsicHeight — alignment comes from the layout, not a
/// shared constant. Sits OUTSIDE the row's Draggable/drop target, so it
/// can never travel with a drag.
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

/// The always-present save-state bar. Dirty: errorContainer with content
/// in the matching on-color so it stays readable — unsaved edits are the
/// one resting state that loses user data (discarded on disconnect), so
/// they earn the error tint the app's other resting states don't get.
/// Clean: a quiet confirmation. One layout
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
// Add-to-empty-slot dialog: the entry fields, with last-seen cells below
// ---------------------------------------------------------------------------

/// The "+" sheet for an empty slot: type a cell in, or tap a cell this app
/// has met before (on any device) to pre-fill the fields and tweak before
/// saving. Either way the slot fills through the one Save button, as a
/// pending edit.
Future<void> showAddToSlot(BuildContext context, RigState rig, int slot) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AddToSlotDialog(rig: rig, slot: slot),
  );
}

/// The add dialog as a stateful widget: the text controllers live in the
/// [State], so they're disposed only when the route's pop animation finally
/// unmounts the dialog.
class _AddToSlotDialog extends StatefulWidget {
  const _AddToSlotDialog({required this.rig, required this.slot});

  final RigState rig;
  final int slot;

  @override
  State<_AddToSlotDialog> createState() => _AddToSlotDialogState();
}

class _AddToSlotDialogState extends State<_AddToSlotDialog> {
  final nameCtrl = TextEditingController();
  final capCtrl = TextEditingController();
  final sensCtrl = TextEditingController();

  @override
  void dispose() {
    nameCtrl.dispose();
    capCtrl.dispose();
    sensCtrl.dispose();
    super.dispose();
  }

  void _pick(RigHistoryEntry entry) {
    final cell = entry.cell;
    setState(() {
      nameCtrl.text = cell.name;
      capCtrl.text = _num(cell.capacityKg);
      sensCtrl.text = _num(cell.sensitivityMvV);
    });
  }

  void _save() {
    final cell = _typedCell(nameCtrl.text, capCtrl.text, sensCtrl.text);
    // The Save button is gated on the same check, so null here is
    // unreachable.
    if (cell == null) return;
    widget.rig.setSlot(widget.slot, cell);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final rig = widget.rig;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Add load cell — ${rigSlotTitle(widget.slot)}'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CellFields(
                nameCtrl: nameCtrl,
                capCtrl: capCtrl,
                sensCtrl: sensCtrl,
                onChanged: () => setState(() {}),
              ),
              const Divider(height: 24),
              if (rig.history.isNotEmpty) ...[
                Text(
                  'Last seen in this app',
                  style: theme.textTheme.labelMedium,
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
                    onTap: () => _pick(entry),
                  ),
              ] else
                Text(
                  'Cells you connect or type in will show up here for '
                  'quick reuse.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              _typedCell(nameCtrl.text, capCtrl.text, sensCtrl.text) != null
              ? _save
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// The name + capacity + sensitivity fields with their quick-pick chips,
/// shared by the add and edit dialogs. [onChanged] fires after any field or
/// chip change so the host dialog can re-validate its Save button.
class _CellFields extends StatelessWidget {
  const _CellFields({
    required this.nameCtrl,
    required this.capCtrl,
    required this.sensCtrl,
    required this.onChanged,
  });

  final TextEditingController nameCtrl;
  final TextEditingController capCtrl;
  final TextEditingController sensCtrl;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
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
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Capacity (kg)'),
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            for (final v in quickCapacitiesKg)
              ActionChip(
                label: Text('${_num(v)} kg'),
                onPressed: () {
                  capCtrl.text = _num(v);
                  onChanged();
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: sensCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Sensitivity (mV/V at full scale)',
            hintText: 'Exact value from the cal cert, e.g. 2.007',
          ),
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            for (final v in quickSensitivitiesMvV)
              ActionChip(
                label: Text('${_num(v)} mV/V'),
                onPressed: () {
                  sensCtrl.text = _num(v);
                  onChanged();
                },
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Slot editor dialog (edit a populated slot)
// ---------------------------------------------------------------------------

/// Edit slot [slot]'s cell. Saving writes a PENDING edit — it reaches the
/// device only via "Save to device".
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

  @override
  void initState() {
    super.initState();
    // The editor only opens from a populated slot.
    final cell = rig.effectiveSlots.cellAt(slot)!;
    nameCtrl = TextEditingController(text: cell.name);
    capCtrl = TextEditingController(text: _num(cell.capacityKg));
    sensCtrl = TextEditingController(text: _num(cell.sensitivityMvV));
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    capCtrl.dispose();
    sensCtrl.dispose();
    super.dispose();
  }

  bool _valid() =>
      _typedCell(nameCtrl.text, capCtrl.text, sensCtrl.text) != null;

  void _save() {
    final cell = _typedCell(nameCtrl.text, capCtrl.text, sensCtrl.text);
    // The Save button is gated on [_valid], so null here is unreachable.
    if (cell == null) return;
    rig.setSlot(slot, cell);
    Navigator.of(context).pop();
  }

  void _clear() {
    rig.clearSlot(slot);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit load cell — ${rigSlotTitle(slot)}'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: _CellFields(
            nameCtrl: nameCtrl,
            capCtrl: capCtrl,
            sensCtrl: sensCtrl,
            onChanged: () => setState(() {}),
          ),
        ),
      ),
      actions: [
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

/// The cell the three field contents describe, or null when either number
/// is missing or non-positive. The add and edit dialogs gate their Save
/// button on this and build their cell from it, so the enable condition and
/// the value committed can never disagree.
LoadCellProfile? _typedCell(String name, String cap, String sens) {
  final c = _typedNumber(cap);
  final s = _typedNumber(sens);
  if (c == null || s == null || c <= 0 || s <= 0) return null;
  return LoadCellProfile(name: name.trim(), capacityKg: c, sensitivityMvV: s);
}

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
