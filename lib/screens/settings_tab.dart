import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_settings.dart';
import '../models/force_unit.dart';
import '../services/ble_link_manager.dart';
import '../widgets/section_header.dart';
import 'app_shell.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final bt = context.watch<BleLinkManager>();
    const bool dart2wasm = bool.fromEnvironment('dart.tool.dart2wasm');

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),

          // App settings
          const SectionHeader('App settings'),
          const SizedBox(height: 16),

          // Display units
          Text('Display Units', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ForceUnit>(
            segments: [
              for (final u in ForceUnit.values)
                ButtonSegment(value: u, label: Text(u.symbol)),
            ],
            selected: {settings.displayUnit},
            // The default selected checkmark steals width from the labels and
            // makes the segments wrap on narrow (mobile) screens.
            showSelectedIcon: false,
            onSelectionChanged: (set) => settings.setDisplayUnit(set.first),
          ),
          const SizedBox(height: 24),

          // Channel labels
          Text('Channels', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (int i = 0; i < settings.channelLabels.length; i++)
            _ChannelConfigTile(
              index: i,
              label: settings.channelLabels[i],
              onLabelChanged: (val) => settings.setChannelLabel(i, val),
            ),
          const SizedBox(height: 24),

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

          // Device settings
          const SectionHeader('Device settings'),
          const SizedBox(height: 16),

          // Device name — not editable yet. Keyed by the name so the field
          // rebuilds with the new value on connect/disconnect. While no link
          // is up, a blurb with a jump to the Devices tab takes its place.
          if (bt.selectedDeviceId.isEmpty)
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.bluetooth_disabled,
                  color: Colors.grey,
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
                    shell?.switchToTab(2);
                  },
                  child: const Text('Connect'),
                ),
              ),
            )
          else
            TextFormField(
              key: ValueKey(bt.connectedDeviceName),
              initialValue: bt.connectedDeviceName,
              enabled: false,
              decoration: const InputDecoration(
                labelText: 'Device name',
                border: OutlineInputBorder(),
              ),
            ),
          const SizedBox(height: 24),

          // About
          const SectionHeader('About'),
          const SizedBox(height: 16),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
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

class _ChannelConfigTile extends StatelessWidget {
  const _ChannelConfigTile({
    required this.index,
    required this.label,
    required this.onLabelChanged,
  });

  final int index;
  final String label;
  final ValueChanged<String> onLabelChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Text(
              'Ch ${index + 1}',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                initialValue: label,
                decoration: const InputDecoration(
                  isDense: true,
                  border: UnderlineInputBorder(),
                  hintText: 'Label',
                ),
                onFieldSubmitted: onLabelChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
