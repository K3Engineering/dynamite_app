import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';

import '../services/ble_link_manager.dart';
import '../services/data_hub.dart';
import '../services/recording_controller.dart';
import '../screens/app_shell.dart';
import '../widgets/channel_stats_table.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_placeholder.dart';
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

  /// dF/dt row + derivative graph visibility. A notifier (not setState) so
  /// toggling rebuilds only the stats/graph/toggles cluster, not the tab.
  final ValueNotifier<bool> _showDerivative = ValueNotifier(false);

  /// Stream-stall flag consumed by [LiveStats]; edge-updated by [_stallTimer]
  /// (running only while streaming) so a stall flips exactly one subtree.
  final ValueNotifier<bool> _stalled = ValueNotifier(false);

  /// App-lifetime singletons, captured (identity-guarded) in
  /// [didChangeDependencies] for listener registration only.
  DataHub? _hub;
  BleLinkManager? _link;

  /// 1 Hz ticker driving the stall check, started/stopped on streaming edges
  /// (see [_onLinkChanged]): during a stall no packets arrive, so the hub
  /// never notifies and nothing else would flip the flag. Runs only while
  /// streaming — with no live trace there is nothing to stall.
  Timer? _stallTimer;

  /// How long the stream may be silent (while the link reports streaming)
  /// before the live stats read as stalled. Packets normally arrive at 50 Hz.
  static const Duration _stallThreshold = Duration(seconds: 2);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // read (not watch): the hub notifies on every decoded packet, which must
    // NOT retrigger didChangeDependencies/build. Both are app-lifetime
    // singletons, so the identity checks below only fire once.
    final hub = context.read<DataHub>();
    if (_hub != hub) {
      _hub?.removeClearedListener(_onHubCleared);
      _hub = hub;
      hub.addClearedListener(_onHubCleared);
    }
    final link = context.read<BleLinkManager>();
    if (_link != link) {
      _link?.removeListener(_onLinkChanged);
      _link = link;
      link.addListener(_onLinkChanged);
    }
  }

  /// A hub reset (a new device stream, see [RecordingController]) means the
  /// previous trace is gone: drop any stale pan/zoom window and follow the
  /// fresh live edge. Without this, a user-panned (non-live) window survives
  /// the disconnect and [GraphController.effectiveRange] would clamp the
  /// stale window against a now-empty buffer (inverted clamp limits -> throw).
  void _onHubCleared() {
    final hub = _hub!;
    _graphCtrl.goLive(totalSamples: hub.totalSamples, oldestSample: 0);
  }

  /// Start/stop the stall ticker on streaming edges. The link manager
  /// notifies for many reasons (RSSI polls included); the edge guard keeps
  /// this a no-op unless streaming actually flipped.
  void _onLinkChanged() {
    final streaming = _link!.isStreaming;
    if (streaming == (_stallTimer != null)) return;
    if (streaming) {
      _stallTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _checkStall(),
      );
    } else {
      _stallTimer?.cancel();
      _stallTimer = null;
      // No live trace — clear the flag so the next stream starts clean.
      _stalled.value = false;
    }
  }

  /// Recompute the stalled flag. The ticker runs only while streaming, so
  /// the link state needs no re-check here.
  void _checkStall() {
    final last = _hub?.lastDataAt;
    final stalled =
        last != null && DateTime.now().difference(last) > _stallThreshold;
    if (stalled != _stalled.value) _stalled.value = stalled;
  }

  @override
  void dispose() {
    _stallTimer?.cancel();
    _hub?.removeClearedListener(_onHubCleared);
    _link?.removeListener(_onLinkChanged);
    _showDerivative.dispose();
    _stalled.dispose();
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
        case StartSessionLinkLost():
          // The link drop itself is announced by the shell's
          // BleConnectionLost notice; this just confirms the REC tap didn't
          // start anything.
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Connection lost — recording not started'),
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

  Future<void> _showRenameDialog(int sessionId, String currentName) =>
      renameSessionFlow(
        context,
        sessionId: sessionId,
        currentName: currentName,
        title: 'Name this session',
      );

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    // Narrow selects: the link manager notifies on every RSSI poll — only
    // streaming edges and device-name changes may rebuild this tab.
    final isConnected = context.select<BleLinkManager, bool>(
      (l) => l.isStreaming,
    );
    final deviceName = context.select<BleLinkManager, String>(
      (l) => l.connectedDeviceName,
    );
    final recording = context.watch<RecordingController>();
    // read (not watch): rebuilding this whole tab per packet would be a
    // rebuild storm — LiveStats/graph subscribe to the hub themselves.
    final hub = context.read<DataHub>();

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
              connectedDeviceName: deviceName,
              protocolErrorSeen: hub.protocolErrorSeen,
            ),
          ),
          if (isConnected)
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: _showDerivative,
                builder: (context, showDerivative, _) => Column(
                  children: [
                    LiveStats(
                      settings: settings,
                      hub: hub,
                      showDerivative: showDerivative,
                      stalledListenable: _stalled,
                    ),
                    Expanded(
                      child: _buildGraphArea(settings, hub, showDerivative),
                    ),
                    ViewToggles(
                      showDerivative: showDerivative,
                      onToggleDerivative: () =>
                          _showDerivative.value = !showDerivative,
                    ),
                  ],
                ),
              ),
            )
          else
            const Expanded(child: DisconnectedPrompt()),
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

  Widget _buildGraphArea(
    AppSettings settings,
    DataHub hub,
    bool showDerivative,
  ) {
    return GraphWorkspace(
      data: hub,
      ctrl: _graphCtrl,
      settings: settings,
      activeChannels: settings.activeChannelIndices,
      showDerivative: showDerivative,
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
              shell?.goToDevices();
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
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
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
  final ValueListenable<bool> stalledListenable;

  const LiveStats({
    super.key,
    required this.settings,
    required this.hub,
    this.showDerivative = false,
    required this.stalledListenable,
  });

  @override
  Widget build(BuildContext context) {
    final unit = settings.displayUnit;

    return ValueListenableBuilder<bool>(
      valueListenable: stalledListenable,
      builder: (context, stalled, _) => ListenableBuilder(
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
                    hub.currentValue(i, unit),
                ],
                emphasized: true,
                stale: stale,
              ),
              ChannelStatsRow(
                label: 'Peak',
                values: [
                  for (int i = 0; i < DataHub.numAdcChannels; i++)
                    hub.peakValue(i, unit),
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
      ),
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
    return EmptyPlaceholder(
      icon: Icons.bluetooth_searching,
      title: 'No device connected',
      action: FilledButton.tonal(
        onPressed: () {
          final shell = context.findAncestorStateOfType<AppShellState>();
          shell?.goToDevices();
        },
        child: const Text('Connect a device'),
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
            labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
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
