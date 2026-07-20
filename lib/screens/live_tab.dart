import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/bucket_series.dart';
import '../models/gap_list.dart';

import '../services/ble_link_manager.dart';
import '../services/data_hub.dart';
import '../services/database.dart';
import '../services/recording_controller.dart';
import '../services/session_storage.dart';
import '../screens/app_shell.dart';
import '../widgets/channel_stats_table.dart';
import '../widgets/graph_components.dart';

// ---------------------------------------------------------------------------
// LiveTab
// ---------------------------------------------------------------------------

class LiveTab extends StatefulWidget {
  const LiveTab({super.key});

  @override
  State<LiveTab> createState() => _LiveTabState();
}

/// Adapts a live [DataHub] to the [GraphDataSource] interface consumed by the
/// shared graph widgets. Forwards the hub's change notifications.
class _LiveDataSource extends ChangeNotifier implements GraphDataSource {
  final DataHub _hub;
  _LiveDataSource(this._hub) {
    _hub.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _hub.removeListener(notifyListeners);
    super.dispose();
  }

  @override
  int get totalSamples => _hub.totalSamples;

  @override
  int get bufferCapacity => DataHub.maxDataSz;

  @override
  int get oldestSample => _hub.totalSamples > DataHub.maxDataSz
      ? _hub.totalSamples - DataHub.maxDataSz
      : 0;

  @override
  int get sampleRate => DataHub.samplesPerSec;

  @override
  double get calibrationSlope => _hub.deviceCalibration.slope;

  @override
  Listenable get repaint => this;

  @override
  ChannelSeries channel(int channelIndex) => (
    data: _hub.rawData[channelIndex],
    min: _hub.rawMin[channelIndex].toDouble(),
    max: _hub.rawMax[channelIndex].toDouble(),
    tare: _hub.tare[channelIndex],
    buckets: _hub.valueBuckets[channelIndex].series,
  );

  @override
  BucketSeries? diffBuckets(int channelIndex) =>
      _hub.diffBuckets[channelIndex].series;

  @override
  GapList get gaps => _hub.gaps;
}

class _LiveTabState extends State<LiveTab> {
  final GraphController _graphCtrl = GraphController(
    minLiveSpan: 20 * DataHub.samplesPerSec,
  );
  bool _showDerivative = false;
  _LiveDataSource? _dataSource;
  DataHub? _hub;
  BleLinkManager? _link;
  bool _wasStreaming = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // read (not watch): the hub notifies on every decoded packet, which must
    // NOT retrigger didChangeDependencies/build. It's an app-lifetime
    // singleton, so the identity check below only fires once.
    final hub = context.read<DataHub>();
    if (_hub != hub) {
      _hub = hub;
      _dataSource?.dispose();
      _dataSource = _LiveDataSource(hub);
    }
    // Same for the link manager (also an app-lifetime singleton): listen for
    // new device streams so the viewport can follow the fresh trace.
    final link = context.read<BleLinkManager>();
    if (_link != link) {
      _link?.removeListener(_onLinkEdge);
      _link = link;
      _wasStreaming = link.isStreaming;
      _link!.addListener(_onLinkEdge);
    }
  }

  /// A new device stream means the hub was just cleared (see
  /// [RecordingController]): drop any stale pan/zoom window and follow the
  /// live edge. Without this, a user-panned (non-live) window survives the
  /// disconnect and [GraphController.effectiveRange] would clamp the stale
  /// window against a now-empty buffer (inverted clamp limits -> throw).
  void _onLinkEdge() {
    final link = _link!;
    final hub = _hub!;
    if (link.isStreaming && !_wasStreaming) {
      _graphCtrl.goLive(
        totalSamples: hub.totalSamples,
        oldestSample: hub.totalSamples > DataHub.maxDataSz
            ? hub.totalSamples - DataHub.maxDataSz
            : 0,
      );
    }
    _wasStreaming = link.isStreaming;
  }

  @override
  void dispose() {
    _link?.removeListener(_onLinkEdge);
    _dataSource?.dispose();
    _graphCtrl.dispose();
    super.dispose();
  }

  void _onTare() {
    context.read<DataHub>().requestTare();
  }

  Future<void> _onToggleRecord() async {
    final recording = context.read<RecordingController>();
    final hub = context.read<DataHub>();
    final settings = context.read<AppSettings>();

    if (recording.sessionInProgress) {
      final result = await recording.stopSession();
      final sessionId = result.sessionId;

      if (!mounted) return;

      // On a storage error stopSession already emitted a RecordingStorageError
      // (surfaced by the shell), so only announce a cleanly saved session.
      if (result.error == null && sessionId != null) {
        // Need to get the name we used when starting
        final session = await AppDatabase.instance.sessionById(sessionId);
        if (!mounted) return;
        final sessionName = session?.name ?? 'Session';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Session saved'),
            behavior: SnackBarBehavior.floating,
            showCloseIcon: true,
            persist: false,
            action: SnackBarAction(
              label: 'Name it',
              onPressed: () => _showRenameDialog(sessionId, sessionName),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } else {
      if (hub.taring) {
        // A tare is still averaging; recording now would persist a zero tare.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Taring in progress — try again in a moment'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final now = DateTime.now();
      final autoName =
          '${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}';

      try {
        final writer = await SessionStorage.startSession(
          dataHub: hub,
          name: autoName,
          channelLabels: settings.channelLabels,
          visibleChannels: settings.activeChannels,
        );
        await recording.startSession(writer);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to start recording: $e'),
              behavior: SnackBarBehavior.floating,
              persist: true,
              showCloseIcon: true,
            ),
          );
        }
      }
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
      await AppDatabase.instance.renameSession(sessionId, newName);
    }
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final link = context.watch<BleLinkManager>();
    final recording = context.watch<RecordingController>();
    // read (not watch): rebuilding this whole tab per packet would be a
    // rebuild storm — LiveStats/graph subscribe to the hub themselves.
    final hub = context.read<DataHub>();
    final isConnected = link.isStreaming;

    return SafeArea(
      child: Column(
        children: [
          LiveStatusBar(
            isConnected: isConnected,
            connectedDeviceName: link.connectedDeviceName,
          ),
          if (isConnected)
            LiveStats(
              settings: settings,
              hub: hub,
              showDerivative: _showDerivative,
            ),
          if (isConnected)
            Expanded(child: _buildGraphArea(settings))
          else
            const Expanded(child: DisconnectedPrompt()),
          if (isConnected)
            ViewToggles(
              showDerivative: _showDerivative,
              onToggleDerivative: () =>
                  setState(() => _showDerivative = !_showDerivative),
            ),
          if (isConnected)
            ActionButtons(
              isRecording: recording.sessionInProgress,
              onToggleRecord: _onToggleRecord,
              onTare: _onTare,
            ),
        ],
      ),
    );
  }

  Widget _buildGraphArea(AppSettings settings) {
    if (_dataSource == null) return const SizedBox.shrink();
    return GraphWorkspace(
      data: _dataSource!,
      ctrl: _graphCtrl,
      settings: settings,
      activeChannels: settings.activeChannelIndices,
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

    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        // During a live gap (dropped packets) the hub reports held values;
        // gray them out so they read as stale rather than fresh readings.
        final stale = hub.liveEdgeIsGap;

        return ChannelStatsTable(
          labels: settings.channelLabels,
          activeChannels: settings.activeChannels,
          onToggleChannel: (i) =>
              settings.setChannelActive(i, !settings.activeChannels[i]),
          unit: unit,
          rows: [
            ChannelStatsRow(
              label: 'Live',
              values: [
                for (int i = 0; i < 4; i++) hub.currentForce(i, unit),
              ],
              emphasized: true,
              stale: stale,
            ),
            ChannelStatsRow(
              label: 'Peak',
              values: [for (int i = 0; i < 4; i++) hub.peakForce(i, unit)],
            ),
            if (showDerivative)
              ChannelStatsRow(
                label: 'dF/dt',
                values: [
                  for (int i = 0; i < 4; i++) hub.currentDerivative(i, unit),
                ],
                stale: stale,
              ),
          ],
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
// ViewToggles
// ---------------------------------------------------------------------------

class ViewToggles extends StatelessWidget {
  final bool showDerivative;
  final VoidCallback onToggleDerivative;

  const ViewToggles({
    super.key,
    this.showDerivative = false,
    required this.onToggleDerivative,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilterChip(
            label: const Text('dF/dt'),
            selected: showDerivative,
            onSelected: (_) => onToggleDerivative(),
            visualDensity: VisualDensity.compact,
            labelStyle: TextStyle(
              fontSize: 12,
              color: showDerivative ? cs.onSecondaryContainer : null,
            ),
          ),
          // Placeholders for future modes can be added here easily
          // const SizedBox(width: 8),
          // FilterChip(label: const Text('FFT'), onSelected: (_) {}),
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
