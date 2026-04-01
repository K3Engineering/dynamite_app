import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/force_unit.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 24),

          // Display units
          Text('Display Units', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ForceUnit>(
            segments: [
              for (final u in ForceUnit.values)
                ButtonSegment(value: u, label: Text(u.symbol)),
            ],
            selected: {settings.displayUnit},
            onSelectionChanged: (set) => settings.setDisplayUnit(set.first),
          ),
          const SizedBox(height: 24),

          // Active channels
          Text('Channels', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (int i = 0; i < 4; i++)
            _ChannelConfigTile(
              index: i,
              label: settings.channelLabels[i],
              active: settings.activeChannels[i],
              onActiveChanged: (val) =>
                  settings.setChannelActive(i, val ?? false),
              onLabelChanged: (val) => settings.setChannelLabel(i, val),
            ),
          const SizedBox(height: 24),

          // User name
          Text('User', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: settings.userName,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
            onFieldSubmitted: settings.setUserName,
            onTapOutside: (_) => FocusScope.of(context).unfocus(),
          ),
          const SizedBox(height: 24),

          // About
          Text('About', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          const Text('Dynamite App v1.0.0'),
        ],
      ),
    );
  }
}

class _ChannelConfigTile extends StatelessWidget {
  const _ChannelConfigTile({
    required this.index,
    required this.label,
    required this.active,
    required this.onActiveChanged,
    required this.onLabelChanged,
  });

  final int index;
  final String label;
  final bool active;
  final ValueChanged<bool?> onActiveChanged;
  final ValueChanged<String> onLabelChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Checkbox(value: active, onChanged: onActiveChanged),
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
