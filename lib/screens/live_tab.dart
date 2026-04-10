import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/force_unit.dart';
import 'package:drift/drift.dart' show Value;
import 'package:google_fonts/google_fonts.dart';

import '../services/bt_handling.dart';
import '../services/database.dart';
import '../services/session_storage.dart';
import '../screens/app_shell.dart';
import '../widgets/graph_components.dart';

// ---------------------------------------------------------------------------
// LiveTab
// ---------------------------------------------------------------------------

class LiveTab extends StatefulWidget {
  const LiveTab({super.key});

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveMinimapDataSource extends ChangeNotifier implements GraphDataSource {
  final DataHub _hub;
  _LiveMinimapDataSource(this._hub) {
    _hub.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _hub.removeListener(notifyListeners);
    super.dispose();
  }

  @override
  int get sampleCount => _hub.rawSz;

  @override
  int get sampleRate => DataHub.samplesPerSec;

  @override
  double get calibrationSlope => _hub.deviceCalibration.slope;

  @override
  List<int> getChannelData(int channelIndex) {
    final lineIdx = DataHub.chanToLine(channelIndex);
    if (lineIdx < 0) return [];
    return _hub.rawData[lineIdx];
  }

  @override
  double getChannelMin(int channelIndex) {
    final lineIdx = DataHub.chanToLine(channelIndex);
    if (lineIdx < 0) return 0.0;
    return _hub.rawMin[lineIdx].toDouble();
  }

  @override
  double getChannelMax(int channelIndex) {
    final lineIdx = DataHub.chanToLine(channelIndex);
    if (lineIdx < 0) return 0.0;
    return _hub.rawMax[lineIdx].toDouble();
  }

  @override
  double getChannelTare(int channelIndex) {
    final lineIdx = DataHub.chanToLine(channelIndex);
    if (lineIdx < 0) return 0.0;
    return _hub.tare[lineIdx];
  }
}

class _LiveTabState extends State<LiveTab> {
  final GraphController _graphCtrl = GraphController();
  bool _showDerivative = false;
  _LiveMinimapDataSource? _dataSource;
  BluetoothHandling? _btHandling;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bt = context.watch<BluetoothHandling>();
    if (_btHandling != bt) {
      _btHandling = bt;
      _dataSource?.dispose();
      _dataSource = _LiveMinimapDataSource(bt.dataHub);
    }
  }

  @override
  void dispose() {
    _dataSource?.dispose();
    _graphCtrl.dispose();
    super.dispose();
  }

  void _onTare() {
    final bt = context.read<BluetoothHandling>();
    bt.dataHub.requestTare();
  }

  Future<void> _onToggleRecord() async {
    final bt = context.read<BluetoothHandling>();
    if (bt.sessionInProgress) {
      bt.stopSession();

      // Auto-save if there's recorded data
      final recordedSamples = bt.dataHub.rawSz - bt.dataHub.recordingStartIdx;
      if (recordedSamples > 0) {
        final settings = context.read<AppSettings>();
        final now = DateTime.now();
        final autoName =
            '${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}';

        try {
          final id = await SessionStorage.saveSession(
            dataHub: bt.dataHub,
            name: autoName,
            channelLabels: settings.channelLabels,
            channelCount: settings.activeChannelCount,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Session saved'),
                action: SnackBarAction(
                  label: 'Name it',
                  onPressed: () => _showRenameDialog(id, autoName),
                ),
                duration: const Duration(seconds: 4),
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
          }
        }
      }
    } else {
      // toggleSession marks the recording start index inside DataHub.
      bt.toggleSession();
    }
  }

  Future<void> _showRenameDialog(int sessionId, String currentName) async {
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Session name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (val) => Navigator.of(ctx).pop(val),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty) {
      await AppDatabase.instance.updateSession(
        sessionId,
        SessionsCompanion(name: Value(newName)),
      );
    }
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final bt = context.watch<BluetoothHandling>();
    final isConnected = bt.isSubscribed;

    return SafeArea(
      child: Column(
        children: [
          LiveStatusBar(
            isConnected: isConnected,
            connectedDeviceName: bt.connectedDeviceName,
          ),
          if (isConnected)
            LiveStats(
              settings: settings,
              hub: bt.dataHub,
              showDerivative: _showDerivative,
            ),
          if (isConnected)
            Expanded(child: _buildGraphArea(bt, settings))
          else
            const Expanded(child: DisconnectedPrompt()),
          if (isConnected)
            ChannelLegend(
              settings: settings,
              showDerivative: _showDerivative,
              onToggleDerivative: () =>
                  setState(() => _showDerivative = !_showDerivative),
            ),
          if (isConnected)
            ActionButtons(
              isRecording: bt.sessionInProgress,
              onToggleRecord: _onToggleRecord,
              onTare: _onTare,
            ),
        ],
      ),
    );
  }

  Widget _buildGraphArea(BluetoothHandling bt, AppSettings settings) {
    if (_dataSource == null) return const SizedBox.shrink();
    return GraphWorkspace(
      data: _dataSource!,
      ctrl: _graphCtrl,
      settings: settings,
      showDerivative: _showDerivative,
    );
  }
}

// ---------------------------------------------------------------------------
// LiveStatusBar
// ---------------------------------------------------------------------------

class LiveStatusBar extends StatelessWidget {
  final bool isConnected;
  final String connectedDeviceName;

  const LiveStatusBar({
    super.key,
    required this.isConnected,
    required this.connectedDeviceName,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isConnected
          ? null
          : () {
              // Navigate to Devices tab
              final shell = context.findAncestorStateOfType<AppShellState>();
              shell?.switchToTab(2);
            },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: isConnected
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.errorContainer,
        child: Row(
          children: [
            Icon(
              isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              size: 18,
              color: isConnected
                  ? Theme.of(context).colorScheme.onPrimaryContainer
                  : Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isConnected
                    ? 'Connected: $connectedDeviceName'
                    : 'Not connected \u2014 tap to connect',
                style: TextStyle(
                  color: isConnected
                      ? Theme.of(context).colorScheme.onPrimaryContainer
                      : Theme.of(context).colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (isConnected)
              Text(
                '${DataHub.samplesPerSec} Hz',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LiveStats
// ---------------------------------------------------------------------------

class LiveStats extends StatelessWidget {
  final AppSettings settings;
  final DataHub hub;
  final bool showDerivative;

  const LiveStats({
    super.key,
    required this.settings,
    required this.hub,
    this.showDerivative = false,
  });

  @override
  Widget build(BuildContext context) {
    final unit = settings.displayUnit;
    final indices = settings.activeChannelIndices;

    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              for (int i = 0; i < indices.length; i++) ...[
                if (i > 0) const SizedBox(width: 16),
                Expanded(
                  child: _ChannelStatChip(
                    label: settings.channelLabels[indices[i]],
                    color: _channelColor(indices[i]),
                    current: hub.currentForce(indices[i], unit),
                    peak: hub.peakForce(indices[i], unit),
                    unit: unit,
                    showDerivative: showDerivative,
                    currentDerivative: showDerivative
                        ? hub.currentDerivative(indices[i], unit)
                        : null,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// DisconnectedPrompt
// ---------------------------------------------------------------------------

class DisconnectedPrompt extends StatelessWidget {
  const DisconnectedPrompt({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bluetooth_searching,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'No device connected',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () {
              final shell = context.findAncestorStateOfType<AppShellState>();
              shell?.switchToTab(2);
            },
            child: const Text('Connect a device'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ChannelLegend (with derivative toggle)
// ---------------------------------------------------------------------------

class ChannelLegend extends StatelessWidget {
  final AppSettings settings;
  final bool showDerivative;
  final VoidCallback onToggleDerivative;

  const ChannelLegend({
    super.key,
    required this.settings,
    this.showDerivative = false,
    required this.onToggleDerivative,
  });

  @override
  Widget build(BuildContext context) {
    final indices = settings.activeChannelIndices;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          // Channel legend items
          for (final idx in indices)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _channelColor(idx),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    settings.channelLabels[idx],
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          const Spacer(),
          // Derivative toggle
          SizedBox(
            height: 28,
            child: FilterChip(
              label: Text(
                'dF/dt',
                style: TextStyle(
                  fontSize: 11,
                  color: showDerivative ? cs.onSecondaryContainer : null,
                ),
              ),
              selected: showDerivative,
              onSelected: (_) => onToggleDerivative(),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ActionButtons
// ---------------------------------------------------------------------------

class ActionButtons extends StatelessWidget {
  final bool isRecording;
  final VoidCallback onToggleRecord;
  final VoidCallback onTare;

  const ActionButtons({
    super.key,
    required this.isRecording,
    required this.onToggleRecord,
    required this.onTare,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          FilledButton.icon(
            onPressed: onToggleRecord,
            icon: Icon(isRecording ? Icons.stop : Icons.fiber_manual_record),
            label: Text(isRecording ? 'STOP' : 'REC'),
            style: FilledButton.styleFrom(
              backgroundColor: isRecording
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary,
              foregroundColor: isRecording
                  ? Theme.of(context).colorScheme.onError
                  : Theme.of(context).colorScheme.onPrimary,
            ),
          ),
          OutlinedButton.icon(
            onPressed: onTare,
            icon: const Icon(Icons.exposure_zero),
            label: const Text('TARE'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Channel stat chip widget
// ---------------------------------------------------------------------------

class _ChannelStatChip extends StatelessWidget {
  const _ChannelStatChip({
    required this.label,
    required this.color,
    required this.current,
    required this.peak,
    required this.unit,
    this.showDerivative = false,
    this.currentDerivative,
  });

  final String label;
  final Color color;
  final double current;
  final double peak;
  final ForceUnit unit;
  final bool showDerivative;
  final double? currentDerivative;

  @override
  Widget build(BuildContext context) {
    final monoStyle = GoogleFonts.robotoMono(
      textStyle: Theme.of(context).textTheme.bodySmall,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
          Text(
            unit.format(current),
            style: GoogleFonts.robotoMono(
              textStyle: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Text('Peak: ${unit.format(peak)}', style: monoStyle),
          if (showDerivative && currentDerivative != null)
            Text(
              'dF/dt: ${unit.formatRate(currentDerivative!)}',
              style: monoStyle,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Channel colors
// ---------------------------------------------------------------------------

Color _channelColor(int index) {
  const colors = [
    Colors.blueAccent,
    Colors.deepOrangeAccent,
    Colors.green,
    Colors.purple,
  ];
  return colors[index % colors.length];
}
