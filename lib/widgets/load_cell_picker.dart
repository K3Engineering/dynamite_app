import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/calibration.dart';
import '../services/adc_protocol.dart';

/// Quick-pick values for the load cell editor: the common nameplate numbers,
/// one tap away; anything else goes in the text field.
const quickCapacitiesKg = <double>[50, 100, 200, 500];
const quickSensitivitiesMvV = <double>[1, 2, 3];

// ---------------------------------------------------------------------------
// Per-channel assignment rows (Settings → Device settings → Load cells)
// ---------------------------------------------------------------------------

/// One assignment row per ADC channel: the currently assigned load cell (or
/// the unassigned state) with a tap-to-assign picker dialog.
class ChannelLoadCellAssignments extends StatelessWidget {
  const ChannelLoadCellAssignments({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int ch = 0; ch < nwNumAdcChan; ch++)
          Card(
            child: ListTile(
              title: Text(
                'Ch ${ch + 1} · ${settings.channelLabels[ch]}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              subtitle: switch (settings.loadCellForChannel(ch)) {
                final cell? => Text(
                  '${cell.title} — ${cell.capacityKg} kg · '
                  '${cell.sensitivityMvV} mV/V',
                ),
                _ => const Text('No load cell — electrical units only'),
              },
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLoadCellAssignment(context, ch),
            ),
          ),
      ],
    );
  }
}

/// The per-channel picker: none, a bank profile, or straight into the editor
/// for a new cell. The assignment is written (mutate-then-pop, so the
/// settings notify can't fire mid-pop-animation) before the dialog closes.
Future<void> showLoadCellAssignment(BuildContext context, int channel) async {
  final settings = context.read<AppSettings>();
  String? selected = settings.channelLoadCellIds[channel];
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('Load cell — Ch ${channel + 1}'),
        content: SizedBox(
          width: 380,
          child: RadioGroup<String?>(
            groupValue: selected,
            onChanged: (v) => setState(() => selected = v),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const RadioListTile<String?>(
                    value: null,
                    title: Text('None'),
                    subtitle: Text('Electrical units only'),
                  ),
                  for (final cell in settings.loadCellBank)
                    RadioListTile<String?>(
                      value: cell.id,
                      title: Text(cell.title),
                      subtitle: Text(
                        '${cell.capacityKg} kg · ${cell.sensitivityMvV} mV/V',
                      ),
                    ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('New load cell…'),
                    onTap: () async {
                      final created = await showLoadCellEditor(ctx, settings);
                      if (created != null && ctx.mounted) {
                        setState(() => selected = created.id);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await settings.assignLoadCell(channel, selected);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Assign'),
          ),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Bank management (Settings → App settings → Load cell bank)
// ---------------------------------------------------------------------------

/// The saved load cell library: tiles with edit-on-tap, delete with an
/// "in use" confirmation, and an add button.
class LoadCellBankSection extends StatelessWidget {
  const LoadCellBankSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final bank = settings.loadCellBank;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bank.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No saved load cells yet. Add one here, or assign one '
              'straight from a channel below.',
            ),
          )
        else
          for (final cell in bank)
            Card(
              child: ListTile(
                title: Text(cell.title),
                subtitle: Text(_subtitle(cell)),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () => _confirmDelete(context, settings, cell),
                ),
                onTap: () =>
                    showLoadCellEditor(context, settings, initial: cell),
              ),
            ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => showLoadCellEditor(context, settings),
          icon: const Icon(Icons.add),
          label: const Text('Add load cell'),
        ),
      ],
    );
  }

  static String _subtitle(LoadCellProfile cell) {
    final parts = <String>[
      '${cell.capacityKg} kg · ${cell.sensitivityMvV} mV/V',
    ];
    if (cell.serial.isNotEmpty) parts.add(cell.serial);
    if (cell.span != 1.0) parts.add('span ×${cell.span}');
    return parts.join(' · ');
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AppSettings settings,
    LoadCellProfile cell,
  ) async {
    final usedBy = settings.channelsUsing(cell.id);
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete load cell?'),
        content: Text(
          usedBy.isEmpty
              ? 'Delete "${cell.title}"?'
              : 'Delete "${cell.title}"? It is assigned to '
                    '${usedBy.map((c) => 'Ch $c').join(', ')} — '
                    'those channels fall back to electrical units.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              // Mutate-then-pop: the settings notify must not fire while
              // the dialog's pop animation still owns the subtree.
              await settings.deleteLoadCell(cell.id);
              if (ctx.mounted) Navigator.of(ctx).pop(true);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Editor dialog (new / edit a profile)
// ---------------------------------------------------------------------------

/// Create or edit a [LoadCellProfile]. Returns the saved profile, or null on
/// cancel. Saving an unnamed new cell with span 1.0 dedupes against the
/// bank's generic profiles (quick picks never litter the bank).
Future<LoadCellProfile?> showLoadCellEditor(
  BuildContext context,
  AppSettings settings, {
  LoadCellProfile? initial,
}) => showDialog<LoadCellProfile>(
  context: context,
  builder: (_) => _LoadCellEditorDialog(settings: settings, initial: initial),
);

/// The editor dialog as a stateful widget: the text controllers live in the
/// [State], so they're disposed only when the route's pop animation finally
/// unmounts the dialog (disposing them when showDialog's future completes
/// would race the outgoing transition and throw "used after disposed").
class _LoadCellEditorDialog extends StatefulWidget {
  const _LoadCellEditorDialog({required this.settings, this.initial});

  final AppSettings settings;
  final LoadCellProfile? initial;

  @override
  State<_LoadCellEditorDialog> createState() => _LoadCellEditorDialogState();
}

class _LoadCellEditorDialogState extends State<_LoadCellEditorDialog> {
  late final TextEditingController nameCtrl;
  late final TextEditingController capCtrl;
  late final TextEditingController sensCtrl;
  late final TextEditingController serialCtrl;
  late final TextEditingController spanCtrl;

  AppSettings get settings => widget.settings;
  LoadCellProfile? get initial => widget.initial;

  @override
  void initState() {
    super.initState();
    nameCtrl = TextEditingController(text: initial?.name ?? '');
    capCtrl = TextEditingController(
      text: initial != null ? _num(initial!.capacityKg) : '',
    );
    sensCtrl = TextEditingController(
      text: initial != null ? _num(initial!.sensitivityMvV) : '',
    );
    serialCtrl = TextEditingController(text: initial?.serial ?? '');
    spanCtrl = TextEditingController(text: _num(initial?.span ?? 1.0));
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    capCtrl.dispose();
    sensCtrl.dispose();
    serialCtrl.dispose();
    spanCtrl.dispose();
    super.dispose();
  }

  bool _valid() =>
      (double.tryParse(capCtrl.text.trim()) ?? 0) > 0 &&
      (double.tryParse(sensCtrl.text.trim()) ?? 0) > 0 &&
      (double.tryParse(spanCtrl.text.trim()) ?? 0) > 0;

  Future<void> _save() async {
    final name = nameCtrl.text.trim();
    final cap = double.parse(capCtrl.text.trim());
    final sens = double.parse(sensCtrl.text.trim());
    final span = double.parse(spanCtrl.text.trim());
    // Mutate-then-pop: the settings notify must not fire while the pop
    // animation still owns the subtree. A new unnamed, uncorrected cell
    // dedupes against the bank's generic profiles.
    final LoadCellProfile saved;
    if (initial == null && name.isEmpty && span == 1.0) {
      saved = await settings.findOrCreateGenericCell(
        capacityKg: cap,
        sensitivityMvV: sens,
      );
    } else {
      saved = LoadCellProfile(
        id: initial?.id ?? settings.mintLoadCellId(),
        name: name,
        capacityKg: cap,
        sensitivityMvV: sens,
        serial: serialCtrl.text.trim(),
        span: span,
      );
      await settings.saveLoadCell(saved);
    }
    if (mounted) Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(initial == null ? 'New load cell' : 'Edit load cell'),
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
                controller: serialCtrl,
                decoration: const InputDecoration(
                  labelText: 'Serial / notes (optional)',
                ),
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
