import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_settings.dart';
import '../models/board_calibration.dart';
import '../models/device_info.dart';
import '../models/display_unit.dart';
import '../services/ble_link_manager.dart';
import '../services/data_hub.dart';
import '../services/rig_state.dart';
import '../widgets/calibration_text.dart';
import '../widgets/connection_info_card.dart';
import '../widgets/device_info_card.dart';
import '../widgets/rig_slots_section.dart';
import '../widgets/section_header.dart';
import 'app_shell.dart';
import 'calibration_screen.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  /// Fetched once per process, not per rebuild of the tab.
  static final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    // Narrow selects: the link manager notifies on every RSSI poll; this
    // section only rebuilds on identity / connection-stat changes.
    final deviceId = context.select<BleLinkManager, String>(
      (l) => l.connectedDeviceId,
    );
    final deviceName = context.select<BleLinkManager, String>(
      (l) => l.connectedDeviceName,
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
    // connect-time read lands for this device.
    final boardCal = context.select<RigState, BoardCalibration?>(
      (r) => r.boardCalibrationFor(deviceId),
    );
    const bool dart2wasm = bool.fromEnvironment('dart.tool.dart2wasm');
    // Unit availability is derived from the hub (the samples-owner), not
    // RigState's per-device document copy: it gates what the connected
    // board can convert right now.
    final availability = context.select<DataHub, UnitAvailability>(
      (h) => resolveUnitAvailability(h, settings.activeChannelIndices),
    );
    final unit = settings.displayUnit.effective(availability);
    final enabledUnits = {
      for (final u in DisplayUnit.values)
        if (u.isAvailable(availability)) u,
    };

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),

          const SectionHeader('App settings'),
          const SizedBox(height: 16),

          Text('Display Units', style: Theme.of(context).textTheme.titleSmall),
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

          // Limit warnings: the master switch. Disabling removes the 1.2 V
          // rail chrome (forbidden-zone fill) from the chart — but not the
          // at-the-rail clip icon in the numbers (a railed converter is data
          // validity, not a warning preference).
          SwitchListTile(
            title: const Text('Limit warnings'),
            subtitle: const Text('Clipped-range indication on the chart'),
            value: settings.limitWarningsEnabled,
            onChanged: settings.setLimitWarningsEnabled,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),

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
                  onPressed: () {
                    // Navigate to the Devices tab (same pattern as Live tab).
                    final shell = context
                        .findAncestorStateOfType<AppShellState>();
                    shell?.goToDevices();
                  },
                  child: const Text('Connect'),
                ),
              ),
            )
          else ...[
            // Device identity, read from the Device Information service at
            // connect time. Read-only; unread fields (e.g. serial on web)
            // render as dashes.
            Text('Device info', style: Theme.of(context).textTheme.titleSmall),
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

            // Device name — not editable yet. Keyed by the name so the
            // field rebuilds with the new value on connect/disconnect.
            TextFormField(
              key: ValueKey(deviceName),
              initialValue: deviceName,
              enabled: false,
              decoration: const InputDecoration(
                labelText: 'Device name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // The connected device's load cell slots (the rig). Read from
            // the device at connect time; edits go back via "Save to
            // device".
            Text('Load cells', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            const RigSlotsSection(),
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
          ],
          const SizedBox(height: 8),

          const SectionHeader('About'),
          const SizedBox(height: 16),
          FutureBuilder<PackageInfo>(
            future: _packageInfo,
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                final packageInfo = snapshot.data!;
                final version =
                    '${packageInfo.version}+${packageInfo.buildNumber}';
                const buildMode = kDebugMode
                    ? 'Debug'
                    : (kProfileMode ? 'Profile' : 'Release');

                String targetInfo = 'Target: ${kIsWeb ? "Web" : "Native"}';
                if (kIsWeb) {
                  targetInfo += ' (${dart2wasm ? "WASM" : "JS"})';
                }

                return Text(
                  'Dynamite App v$version\n'
                  'Build Mode: $buildMode\n'
                  '$targetInfo',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                );
              }
              return const SizedBox.shrink(); // Hide while loading
            },
          ),
        ],
      ),
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
