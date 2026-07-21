import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';

import '../services/ble_link_manager.dart';
import '../services/data_hub.dart';
import '../services/database.dart';
import '../services/recording_controller.dart';
import '../screens/app_shell.dart';
import '../widgets/channel_stats_table.dart';
import '../widgets/dialogs.dart';
import '../widgets/graph_components.dart';

// ---------------------------------------------------------------------------
// LiveTab
// ---------------------------------------------------------------------------

class LiveTab extends StatefulWidget {
  const LiveTab({super.key});

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<LiveTab> {
  final GraphController _graphCtrl = GraphController(
    minLiveSpan: 20 * DataHub.samplesPerSec,
  );
  bool _showDerivative = false;
  DataHub? _hub;

  /// Last seen hub generation; a change means the hub was cleared for a new
  /// device stream (see [RecordingController]).
  int _lastGeneration = 0;

  /// How long the stream may be silent (while the link reports streaming)
  /// before the live stats read as stalled. Packets normally arrive at 50 Hz.
  static const Duration _stallThreshold = Duration(seconds: 2);

  /// 1 Hz ticker driving the stall check: during a stall no packets arrive,
  /// so the hub never notifies and nothing else would flip the flag.
  Timer? _stallTimer;
  bool _stalled = false;

  @override
  void initState() {
    super.initState();
    _stallTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkStall(),
    );
  }

  /// Recompute the stalled flag; rebuilds ONLY on an edge (per-tick setState
  /// would be a pointless 1 Hz rebuild of the whole tab).
  void _checkStall() {
    final hub = _hub;
    if (hub == null) return;
    final last = hub.lastDataAt;
    final stalled =
        context.read<BleLinkManager>().isStreaming &&
        last != null &&
        DateTime.now().difference(last) > _stallThreshold;
    if (stalled != _stalled) {
      setState(() => _stalled = stalled);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // read (not watch): the hub notifies on every decoded packet, which must
    // NOT retrigger didChangeDependencies/build. It's an app-lifetime
    // singleton, so the identity check below only fires once.
    final hub = context.read<DataHub>();
    if (_hub != hub) {
      _hub?.removeListener(_onHubChanged);
      _hub = hub;
      _lastGeneration = hub.generation;
      hub.addListener(_onHubChanged);
    }
  }

  /// A hub reset (its generation bumped by [DataHub.clear]) means a new
  /// device stream just cleared the previous trace: drop any stale pan/zoom
  /// window and follow the fresh live edge. Without this, a user-panned
  /// (non-live) window survives the disconnect and
  /// [GraphController.effectiveRange] would clamp the stale window against a
  /// now-empty buffer (inverted clamp limits -> throw).
  void _onHubChanged() {
    final hub = _hub!;
    if (hub.generation != _lastGeneration) {
      _lastGeneration = hub.generation;
      _graphCtrl.goLive(totalSamples: hub.totalSamples, oldestSample: 0);
    }
  }

  @override
  void dispose() {
    _stallTimer?.cancel();
    _hub?.removeListener(_onHubChanged);
    _graphCtrl.dispose();
    super.dispose();
  }

  void _onTare() {
    context.read<DataHub>().requestTare();
  }

  Future<void> _onToggleRecord() async {
    final recording = context.read<RecordingController>();

    if (recording.sessionInProgress) {
      final result = await recording.stopSession();
      final sessionId = result.sessionId;

      if (!mounted) return;

      // On a storage error stopSession already emitted a RecordingStorageError
      // (surfaced by the shell), so only announce a cleanly saved session.
      if (result.error == null && sessionId != null) {
        final sessionName = result.name ?? 'Session';
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
      final settings = context.read<AppSettings>();
      final result = await recording.startSession(
        channelLabels: settings.channelLabels,
        visibleChannels: settings.activeChannels,
      );

      if (!mounted) return;

      switch (result) {
        case StartSessionOk() || null:
          // Recording (or already was, which the button state prevents). No
          // announcement on start.
          break;
        case StartSessionTareInProgress():
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Taring in progress — try again in a moment'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        case StartSessionFailed(:final error):
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to start recording: $error'),
              behavior: SnackBarBehavior.floating,
              persist: true,
              showCloseIcon: true,
            ),
          );
      }
    }
  }

  Future<void> _showRenameDialog(int sessionId, String currentName) async {
    final newName = await showTextPrompt(
      context,
      title: 'Name this session',
      label: 'Session name',
      initial: currentName,
    );
    if (newName != null && newName.isNotEmpty) {
      await AppDatabase.instance.renameSession(sessionId, newName);
    }
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
          // The bar shows the hub's protocol-error latch, which changes with
          // packet traffic — listen to the hub (per-packet notify) here
          // rather than rebuilding the whole tab.
          ListenableBuilder(
            listenable: hub,
            builder: (context, _) => LiveStatusBar(
              isConnected: isConnected,
              connectedDeviceName: link.connectedDeviceName,
              protocolErrorSeen: hub.protocolErrorSeen,
            ),
          ),
          if (isConnected)
            LiveStats(
              settings: settings,
              hub: hub,
              showDerivative: _showDerivative,
              stalled: _stalled,
            ),
          if (isConnected)
            Expanded(child: _buildGraphArea(settings, hub))
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

  Widget _buildGraphArea(AppSettings settings, DataHub hub) {
    return GraphWorkspace(
      data: hub,
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

  /// Whether a malformed ADC packet was seen on this stream
  /// ([DataHub.protocolErrorSeen]). Shows a persistent warning marker: bad
  /// packets are dropped but never hidden from the user.
  final bool protocolErrorSeen;

  const LiveStatusBar({
    super.key,
    required this.isConnected,
    required this.connectedDeviceName,
    this.protocolErrorSeen = false,
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
            if (isConnected && protocolErrorSeen)
              Tooltip(
                message:
                    'Malformed ADC packets received — '
                    'firmware/protocol mismatch',
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    Icons.warning_amber,
                    size: 18,
                    color: Theme.of(context).colorScheme.error,
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

  /// The stream has gone silent while the link reports streaming (no packets
  /// for [_LiveTabState._stallThreshold]). Values are grayed out like a gap.
  final bool stalled;

  const LiveStats({
    super.key,
    required this.settings,
    required this.hub,
    this.showDerivative = false,
    this.stalled = false,
  });

  @override
  Widget build(BuildContext context) {
    final unit = settings.displayUnit;

    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        // During a live gap (dropped packets) the hub reports held values;
        // gray them out so they read as stale rather than fresh readings.
        // Same for a stall: the newest "reading" is just the last one.
        final stale = hub.liveEdgeIsGap || stalled;

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
                for (int i = 0; i < DataHub.numAdcChannels; i++)
                  hub.currentForce(i, unit),
              ],
              emphasized: true,
              stale: stale,
            ),
            ChannelStatsRow(
              label: 'Peak',
              values: [
                for (int i = 0; i < DataHub.numAdcChannels; i++)
                  hub.peakForce(i, unit),
              ],
            ),
            if (showDerivative)
              ChannelStatsRow(
                label: 'dF/dt',
                values: [
                  for (int i = 0; i < DataHub.numAdcChannels; i++)
                    hub.currentDerivative(i, unit),
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
