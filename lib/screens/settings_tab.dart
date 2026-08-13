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
import '../services/rig_state.dart';
import '../widgets/calibration_text.dart';
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
    // Narrow selects: the link manager notifies on every RSSI poll, but the
    // device section only cares about identity changes.
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
    // The board-calibration row's one-line state; null until the
    // connect-time read lands for this device.
    final boardCal = context.select<RigState, BoardCalibration?>(
      (r) => r.boardCalibrationFor(deviceId),
    );
    const bool dart2wasm = bool.fromEnvironment('dart.tool.dart2wasm');

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
          ),
          _UnitGroup(
            label: 'Electrical',
            units: [
              for (final u in DisplayUnit.values)
                if (!u.isForce) u,
            ],
          ),
          const SizedBox(height: 16),

          // Limit warnings: master switch + the warning rung. Disabling
          // removes the limit chrome from the chart (ribbons, rail flood
          // and dashes) and the numbers — but not the at-the-rail clip
          // icon (a railed converter is data validity, not a warning
          // preference).
          SwitchListTile(
            title: const Text('Limit warnings'),
            subtitle: const Text(
              'Caution and full-scale indication on the chart and live numbers',
            ),
            value: settings.limitWarningsEnabled,
            onChanged: settings.setLimitWarningsEnabled,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 4),
          Opacity(
            opacity: settings.limitWarningsEnabled ? 1.0 : 0.5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _limitRungDescription(settings.lcWarnFraction),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                // A label per stop, positioned by stop index (the stops are
                // non-uniform past FSR). The 100% detent — where the warning
                // and the limit swap roles — is emphasized.
                const _SliderStopLabels(
                  stops: AppSettings.lcWarnFractionStops,
                ),
                Slider(
                  value: _nearestStopIndex(
                    settings.lcWarnFraction,
                  ).toDouble(),
                  min: 0,
                  max: AppSettings.lcWarnFractionStops.length - 1,
                  divisions: AppSettings.lcWarnFractionStops.length - 1,
                  label:
                      '${(settings.lcWarnFraction * 100).round()}%',
                  onChanged: settings.limitWarningsEnabled
                      ? (v) => unawaited(
                          settings.setLcWarnFraction(
                            AppSettings.lcWarnFractionStops[v.round()],
                          ),
                        )
                      : null,
                ),
              ],
            ),
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
  const _UnitGroup({required this.label, required this.units});

  final String label;
  final List<DisplayUnit> units;

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
              ButtonSegment(value: u, label: Text(u.symbol)),
          ],
          selected: {settings.displayUnit},
          // The default selected checkmark steals width from the labels
          // and makes the segments wrap on narrow (mobile) screens.
          showSelectedIcon: false,
          onSelectionChanged: (set) =>
              unawaited(settings.setDisplayUnit(set.first)),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// The limit-setting description. FSR is always one rung and the setting the
/// other; the roles swap at the 100% detent.
String _limitRungDescription(double fraction) {
  final pct = (fraction * 100).round();
  final rungs = fraction < 1.0
      ? 'Warning band from $pct% to 100% of the load cell rating; past the '
            'rating is the limit.'
      : fraction > 1.0
      ? 'Warning at the load cell rating; the limit is at $pct% of it.'
      : 'Warning and limit are both at the load cell rating.';
  return '$rungs With no cell assigned, the ADC range is the limit.';
}

/// The slider works in stop indices; map the stored fraction to the closest
/// stop.
int _nearestStopIndex(double fraction) {
  const stops = AppSettings.lcWarnFractionStops;
  var best = 0;
  for (var i = 1; i < stops.length; i++) {
    if ((stops[i] - fraction).abs() < (stops[best] - fraction).abs()) {
      best = i;
    }
  }
  return best;
}

/// A label per slider stop, positioned by stop index (the stops are
/// non-uniform past FSR, so a Row won't line them up). The 100% detent —
/// where the warning and the limit swap roles — is emphasized.
class _SliderStopLabels extends StatelessWidget {
  const _SliderStopLabels({required this.stops});

  final List<double> stops;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final detentStyle = style?.copyWith(
      fontWeight: FontWeight.bold,
      color: theme.colorScheme.primary,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // The slider track is inset by the thumb radius on both sides; stop
        // i sits at i/(N-1) of the track.
        const double inset = 24;
        const double labelW = 26;
        final track = constraints.maxWidth - 2 * inset;
        return SizedBox(
          height: 14,
          child: Stack(
            children: [
              for (var i = 0; i < stops.length; i++)
                Positioned(
                  left:
                      (inset + track * i / (stops.length - 1) - labelW / 2)
                          .clamp(0.0, constraints.maxWidth - labelW),
                  child: SizedBox(
                    width: labelW,
                    child: Text(
                      stops[i] == 1.0
                          ? '100%'
                          : '${(stops[i] * 100).round()}',
                      textAlign: TextAlign.center,
                      style: stops[i] == 1.0 ? detentStyle : style,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
