import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/app_meta.dart';
import '../services/app_settings.dart';
import '../models/board_calibration.dart';
import '../models/bt_scan.dart';
import '../models/device_info.dart';
import '../models/device_name.dart';
import '../models/display_unit.dart';
import '../services/ble_link_manager.dart';
import '../services/data_hub.dart';
import '../services/firmware_update_service.dart';
import '../services/rig_state.dart';
import '../widgets/bt_icon.dart';
import '../widgets/calibration_text.dart';
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

  /// The "Connect" action shown while no device is linked.
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
    final linkState = context.select<BleLinkManager, BtLinkState>(
      (l) => l.linkState,
    );
    // Narrow selects: the link manager notifies per RSSI poll.
    final deviceId = context.select<BleLinkManager, String>(
      (l) => l.connectedDeviceId,
    );
    final storedName = context.select<BleLinkManager, String?>(
      (l) => l.connectedStoredDeviceName,
    );
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
    final boardCal = context.select<RigState, BoardCalibration?>(
      (r) => r.boardCalibration,
    );
    const bool dart2wasm = bool.fromEnvironment('dart.tool.dart2wasm');
    final availability = context.select<DataHub, UnitAvailability>(
      (h) => h.unitAvailability,
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

              SwitchListTile(
                title: const Text('Keep screen awake'),
                subtitle: const Text(
                  'Prevents the screen from turning off while connected to a device.',
                ),
                value: settings.wakelockEnabled,
                onChanged: settings.setWakelockEnabled,
                contentPadding: EdgeInsets.zero,
              ),

              SwitchListTile(
                title: const Text('Show debug values in Live view'),
                subtitle: const Text(
                  'Adds a per-channel AC RMS row to the live view.',
                ),
                value: settings.showDebugLiveValues,
                onChanged: settings.setShowDebugLiveValues,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 24),

              const SectionHeader('Device settings'),
              const SizedBox(height: 16),

              if (linkState == BtLinkState.idle)
                Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.bluetooth_disabled,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    title: const Text('No device connected'),
                    subtitle: const Text(
                      'Connect to a device to manage its settings',
                    ),
                    trailing: FilledButton(
                      onPressed: widget.onGoToDevices,
                      child: const Text('Connect'),
                    ),
                  ),
                )
              else if (linkState != BtLinkState.streaming)
                // A link in transition: device-owned facts aren't readable
                // yet, so don't mount against placeholders.
                Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.bluetooth_searching,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    title: Text(btLinkStateLabel(linkState)!),
                    subtitle: const Text(
                      'Device settings appear when the device is ready',
                    ),
                  ),
                )
              else ...[
                Text(
                  'Device info',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                DeviceInfoCard(info: deviceInfo!),
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

                // Keyed by device and stored value so the editor resets on
                // connect and save.
                _DeviceNameEditor(
                  key: ValueKey('$deviceId/${storedName ?? ''}'),
                  storedName: storedName,
                ),
                const SizedBox(height: 16),

                Text(
                  'Load cells',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                RigSlotsSection(rig: context.read<RigState>()),
                const SizedBox(height: 16),

                // Tappable whenever a board object is held, invalid included.
                Card(
                  child: ListTile(
                    title: const Text('Board calibration'),
                    subtitle: Text(boardCalibrationStatusLine(boardCal)),
                    trailing: boardCal == null
                        ? null
                        : const Icon(Icons.chevron_right),
                    onTap: boardCal == null
                        ? null
                        : () => Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  CalibrationScreen(deviceId: deviceId),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 16),

                _FirmwareCard(onGoToDevices: widget.onGoToDevices),
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

/// The OTA firmware card.
class _FirmwareCard extends StatelessWidget {
  const _FirmwareCard({required this.onGoToDevices});

  /// Passed through to the update screen's "Done".
  final VoidCallback onGoToDevices;

  @override
  Widget build(BuildContext context) {
    final service = context.watch<FirmwareUpdateService>();
    final String subtitle = switch (service.checkState) {
      CheckNeverRan() => 'Tap to check for updates',
      CheckRunning() => 'Checking for updates…',
      CheckOk(:final result) when result.target == null =>
        'No release available',
      CheckOk(:final result) when result.differsFromDevice =>
        'Update available',
      CheckOk() => 'Up to date',
      CheckFailed() => 'Check failed',
    };
    return Card(
      child: ListTile(
        title: const Text('Firmware update'),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => FirmwareUpdateScreen(onDone: onGoToDevices),
          ),
        ),
      ),
    );
  }
}

/// The device-name editor: an explicit save (not fire-on-change). Empty input
/// reverts the device to its factory name.
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

/// One unit family's row in the display-units picker.
class _UnitGroup extends StatelessWidget {
  const _UnitGroup({
    required this.label,
    required this.units,
    required this.selected,
    required this.enabled,
  });

  final String label;
  final List<DisplayUnit> units;

  /// The effective unit; the other group shows an empty selection.
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
