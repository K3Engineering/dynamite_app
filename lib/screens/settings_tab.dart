import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/app_meta.dart';
import '../services/app_settings.dart';
import '../models/board_calibration.dart';
import '../models/device_info.dart';
import '../models/device_name.dart';
import '../models/display_unit.dart';
import '../services/ble_link_manager.dart';
import '../services/data_hub.dart';
import '../services/firmware_update_service.dart';
import '../services/rig_state.dart';
import '../services/calibration_text.dart';
import '../widgets/info_cards.dart';
import '../widgets/middle_click_autoscroll.dart';
import '../widgets/rig_slots_section.dart';
import '../widgets/section_header.dart';
import '../widgets/snackbars.dart';
import '../widgets/wide_layout.dart';
import 'calibration_screen.dart';
import 'firmware_update_screen.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key, required this.onGoToDevices});

  /// The "Connect" action shown while no device is linked: jumps to the
  /// Devices tab. Supplied by the app shell, which owns the tab index.
  final VoidCallback onGoToDevices;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final appMeta = context.read<AppMeta>();
    // Narrow selects: the link manager notifies on every RSSI poll; this
    // section only rebuilds on identity / connection-stat changes.
    final deviceId = context.select<BleLinkManager, String>(
      (l) => l.connectedDeviceId,
    );
    final storedName = context.select<BleLinkManager, String?>(
      (l) => l.connectedStoredDeviceName,
    );
    // The connect-time DIS identity read; null until it lands.
    final deviceInfo = context.select<BleLinkManager, DeviceInfo?>(
      (l) => l.connectedDeviceInfo,
    );
    final negotiatedMtu = context.select<BleLinkManager, int?>(
      (l) => l.negotiatedMtu,
    );
    final minPacketBytes = context.select<BleLinkManager, int?>(
      (l) => l.minAdcPacketBytes,
    );
    final maxPacketBytes = context.select<BleLinkManager, int?>(
      (l) => l.maxAdcPacketBytes,
    );
    // The board-calibration row's one-line state; null until the
    // connect-time read lands.
    final boardCal = context.select<RigState, BoardCalibration?>(
      (r) => r.boardCalibration,
    );
    const bool dart2wasm = bool.fromEnvironment('dart.tool.dart2wasm');
    // Unit availability is derived from the hub (the samples-owner), not
    // RigState's per-device document copy: it gates what the connected
    // board can convert right now.
    final availability = context.select<DataHub, UnitAvailability>(
      (h) => resolveUnitAvailability(
        h.calibrationFor,
        settings.activeChannelIndices,
      ),
    );
    final unit = settings.displayUnit.effective(availability);
    final enabledUnits = {
      for (final u in DisplayUnit.values)
        if (u.isAvailable(availability)) u,
    };

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => MiddleClickAutoscroll(
          controller: _scrollController,
          child: ListView(
            controller: _scrollController,
            padding: EdgeInsets.symmetric(
              horizontal: contentSideInset(constraints.maxWidth),
              vertical: 16,
            ),
            children: [
              Text(
                'Settings',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),

              const SectionHeader('App settings'),
              const SizedBox(height: 16),

              Text(
                'Display Units',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              _UnitGroup(
                label: 'Force',
                units: [
                  for (final u in DisplayUnit.values)
                    if (u.isForce) u,
                ],
                selected: unit,
                enabled: enabledUnits,
              ),
              _UnitGroup(
                label: 'Electrical',
                units: [
                  for (final u in DisplayUnit.values)
                    if (!u.isForce) u,
                ],
                selected: unit,
                enabled: enabledUnits,
              ),
              const SizedBox(height: 16),

              // Wakelock
              SwitchListTile(
                title: const Text('Keep screen awake'),
                subtitle: const Text(
                  'Prevents the screen from turning off while connected to a device.',
                ),
                value: settings.wakelockEnabled,
                onChanged: settings.setWakelockEnabled,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 24),

              const SectionHeader('Device settings'),
              const SizedBox(height: 16),

              if (deviceId.isEmpty)
                Card(
                  child: ListTile(
                    // The dim "nothing here" affordance: the theme's outline
                    // role, as in EmptyPlaceholder — not a raw Material grey.
                    leading: Icon(
                      Icons.bluetooth_disabled,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    title: const Text('No device connected'),
                    subtitle: const Text(
                      'Connect to a device to manage its settings',
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: widget.onGoToDevices,
                      child: const Text('Connect'),
                    ),
                  ),
                )
              else ...[
                // Device identity, read from the Device Information service at
                // connect time. Read-only; unread fields (e.g. serial on web)
                // render as dashes.
                Text(
                  'Device info',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                DeviceInfoCard(info: deviceInfo),
                const SizedBox(height: 16),

                Text(
                  'Connection info',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                ConnectionInfoCard(
                  mtu: negotiatedMtu,
                  minPacketBytes: minPacketBytes,
                  maxPacketBytes: maxPacketBytes,
                ),
                const SizedBox(height: 16),

                // The Settings-namespace device name. Keyed by device and
                // stored value so the editor resets on connect/disconnect and
                // after a save.
                _DeviceNameEditor(
                  key: ValueKey('$deviceId/${storedName ?? ''}'),
                  storedName: storedName,
                ),
                const SizedBox(height: 16),

                // The connected device's load cell slots (the rig). Read from
                // the device at connect time; edits go back via "Save to
                // device".
                Text(
                  'Load cells',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                RigSlotsSection(rig: context.read<RigState>()),
                const SizedBox(height: 16),

                Card(
                  child: ListTile(
                    title: const Text('Board calibration'),
                    subtitle: Text(boardCalibrationStatusLine(boardCal)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => CalibrationScreen(deviceId: deviceId),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // OTA entry point: the check itself lives with the service
                // (auto-checked once per link); the card just summarizes.
                const _FirmwareCard(),
                const SizedBox(height: 16),
              ],
              const SizedBox(height: 8),

              const SectionHeader('About'),
              const SizedBox(height: 16),
              Builder(
                builder: (context) {
                  const buildMode = kDebugMode
                      ? 'Debug'
                      : (kProfileMode ? 'Profile' : 'Release');

                  var targetInfo = 'Target: ${kIsWeb ? "Web" : "Native"}';
                  if (kIsWeb) {
                    targetInfo += ' (${dart2wasm ? "WASM" : "JS"})';
                  }

                  return Text(
                    'Dynamite App v${appMeta.versionLabel}\n'
                    'Build Mode: $buildMode\n'
                    '$targetInfo',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The OTA firmware card: a one-line status, pushing the update screen that
/// shows the actual versions.
class _FirmwareCard extends StatelessWidget {
  const _FirmwareCard();

  @override
  Widget build(BuildContext context) {
    final service = context.watch<FirmwareUpdateService>();
    final check = service.check;
    final String subtitle;
    if (service.checking && check == null) {
      subtitle = 'Checking for updates…';
    } else if (check == null) {
      subtitle = 'Tap to check for updates';
    } else if (check.target == null) {
      subtitle = 'No release available';
    } else if (check.differsFromDevice) {
      subtitle = 'Update available';
    } else {
      subtitle = 'Up to date';
    }
    return Card(
      child: ListTile(
        title: const Text('Firmware update'),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const FirmwareUpdateScreen()),
        ),
      ),
    );
  }
}

/// The device-name editor: the Settings-namespace name with an explicit
/// save (device edits are deliberate, not fire-on-change, and failures
/// surface as snackbars). Empty input clears the stored name — the device
/// reverts to its factory name.
class _DeviceNameEditor extends StatefulWidget {
  const _DeviceNameEditor({super.key, required this.storedName});

  /// The device's stored name, null when unset.
  final String? storedName;

  @override
  State<_DeviceNameEditor> createState() => _DeviceNameEditorState();
}

class _DeviceNameEditorState extends State<_DeviceNameEditor> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.storedName ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final link = context.read<BleLinkManager>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    String? error;
    try {
      if (!await link.setDeviceName(_controller.text)) {
        error = 'The device rejected the name.';
      }
    } catch (e) {
      error = 'Rename failed: $e';
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      showErrorSnackBar(messenger, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _controller.text.trim();
    final dirty = trimmed != (widget.storedName ?? '');
    final invalid = trimmed.isNotEmpty && !isValidDeviceName(trimmed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          maxLength: deviceNameMaxLength,
          enabled: !_saving,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Device name',
            border: const OutlineInputBorder(),
            counterText: '',
            helperText: 'Empty reverts to the factory name.',
            errorText: invalid
                ? 'Up to $deviceNameMaxLength characters: start with a '
                      "letter or digit, then letters, digits, spaces or . _ ( ) - '"
                : null,
          ),
        ),
        // Same never-moving layout as the rig save bar.
        Visibility(
          visible: dirty,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const Key('device_name_revert'),
                onPressed: _saving
                    ? null
                    : () => setState(
                        () => _controller.text = widget.storedName ?? '',
                      ),
                child: const Text('Revert'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('device_name_save'),
                onPressed: dirty && !invalid && !_saving ? _save : null,
                child: Text(_saving ? 'Saving…' : 'Save to device'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One row of the display-units picker: a label above a segmented button
/// covering one unit family (force or electrical).
class _UnitGroup extends StatelessWidget {
  const _UnitGroup({
    required this.label,
    required this.units,
    required this.selected,
    required this.enabled,
  });

  final String label;
  final List<DisplayUnit> units;

  /// The unit the instrument draws (the effective preference); lives in one
  /// of the two groups, the other shows an empty selection.
  final DisplayUnit selected;

  /// The units the board/rig can convert right now.
  final Set<DisplayUnit> enabled;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        SegmentedButton<DisplayUnit>(
          segments: [
            for (final u in units)
              ButtonSegment(
                value: u,
                label: Text(u.symbol),
                enabled: enabled.contains(u),
              ),
          ],
          selected: {if (units.contains(selected)) selected},
          emptySelectionAllowed: true,
          // The default selected checkmark steals width from the labels
          // and makes the segments wrap on narrow (mobile) screens.
          showSelectedIcon: false,
          onSelectionChanged: (set) {
            if (set.isEmpty) return;
            unawaited(settings.setDisplayUnit(set.first));
          },
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
