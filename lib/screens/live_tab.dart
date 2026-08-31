import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';
import '../models/board_calibration.dart';
import '../models/channel_limits.dart';
import '../models/display_unit.dart';

import '../models/bt_scan.dart';
import '../models/device_profile.dart';
import '../services/ble_link_manager.dart';
import '../services/data_hub.dart';
import '../services/feed_health_tracker.dart';
import '../models/feed_health.dart';
import '../models/hub_event.dart';
import '../widgets/feed_health_text.dart';
import '../services/recording_controller.dart';
import '../services/rig_state.dart';
import '../widgets/bt_icon.dart';
import '../widgets/channel_stats_table.dart';
import '../widgets/tare_sheet.dart';
import '../widgets/session_flows.dart';
import '../widgets/empty_placeholder.dart';
import '../widgets/graph_components.dart';
import '../widgets/rssi_indicator.dart';
import '../widgets/snackbars.dart';
import '../status_colors.dart';

// ---------------------------------------------------------------------------
// LiveTab
// ---------------------------------------------------------------------------

class LiveTab extends StatefulWidget {
  const LiveTab({super.key, required this.onGoToDevices});

  /// Jump to the Devices tab (the idle prompt's "Connect a device" action).
  /// Supplied by the app shell, which owns the tab index.
  final VoidCallback onGoToDevices;

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<LiveTab> {
  // Live window floor: 20 s in samples at the 1 kHz the device boots at (a
  // UI anchor, like the hub's ring capacity — not read from the device).
  final GraphController _graphCtrl = GraphController(minLiveSpan: 20 * 1000);

  /// dF/dt row + derivative graph visibility. A notifier (not setState) so
  /// toggling rebuilds only the stats/graph/toggles cluster, not the tab.
  final ValueNotifier<bool> _showDerivative = ValueNotifier(false);

  /// App-lifetime hub, captured (identity-guarded) in
  /// [didChangeDependencies] for listener registration only.
  DataHub? _hub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // read (not watch): the hub notifies on every decoded packet, which must
    // NOT retrigger didChangeDependencies/build. The hub is an app-lifetime
    // singleton, so the identity check below only fires once.
    final hub = context.read<DataHub>();
    if (_hub != hub) {
      _hub?.removeEventListener(_onHubEvent);
      _hub = hub;
      hub.addEventListener(_onHubEvent);
    }
  }

  /// A hub reset (a new device stream, see `StreamResetCoordinator`) means the
  /// previous trace is gone: drop any stale pan/zoom window and follow the
  /// fresh live edge. Without this, a user-panned (non-live) window survives
  /// the disconnect and [GraphController.effectiveRange] would clamp the
  /// stale window against a now-empty buffer (inverted clamp limits -> throw).
  void _onHubEvent(HubEvent event) {
    if (event is HubCleared) _graphCtrl.reset();
  }

  @override
  void dispose() {
    _hub?.removeEventListener(_onHubEvent);
    _showDerivative.dispose();
    _graphCtrl.dispose();
    super.dispose();
  }

  void _onTare() {
    // A session freezes its tares at record start, so re-zeroing mid-recording
    // would desync the live display from the export. Refuse loudly.
    if (context.read<RecordingController>().sessionInProgress) {
      showErrorSnackBar(
        ScaffoldMessenger.of(context),
        'Stop recording to tare',
      );
      return;
    }
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
      final hub = context.read<DataHub>();
      final result = recording.startSession(
        // Row titles are the rig's cell names (or 'CH n'), snapshotted into
        // the session at record time.
        channelLabels: context.read<RigState>().channelTitles,
        visibleChannels: settings.activeChannels,
        // Frozen as the CSV export's default converted unit — the unit
        // the instrument is actually drawing, not a disabled preference.
        displayUnit: settings.displayUnit.effective(
          resolveUnitAvailability(
            hub.calibrationFor,
            settings.activeChannelIndices,
          ),
        ),
      );

      switch (result) {
        case StartSessionOk() || StartSessionBusy():
          // Recording (or another lifecycle op is in flight, which the
          // button state prevents). No announcement on start.
          break;
        case StartSessionTareInProgress():
          showErrorSnackBar(
            ScaffoldMessenger.of(context),
            'Taring in progress — try again in a moment',
          );
        case StartSessionNoData():
          showErrorSnackBar(
            ScaffoldMessenger.of(context),
            'No data from device — recording not started',
          );
      }
    }
  }

  Future<void> _showRenameDialog(String sessionId, String currentName) =>
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
    // link-state transitions and device-name changes may rebuild this tab.
    final linkState = context.select<BleLinkManager, BtLinkState>(
      (l) => l.linkState,
    );
    final streaming = linkState == BtLinkState.streaming;
    final deviceName = context.select<BleLinkManager, String>(
      (l) => l.connectedDeviceName,
    );
    final recording = context.watch<RecordingController>();
    // RigState notifies only on flash reads and slot edits (never per
    // packet), so watching it here is cheap.
    final rig = context.watch<RigState>();
    // read (not watch): rebuilding this whole tab per packet would be a
    // lot of rebuilds — LiveStats/graph subscribe to the hub themselves.
    final hub = context.read<DataHub>();

    // The feed-health classification (banner, stats graying) comes from the
    // shared FeedHealthTracker: one derivation owner for this tab and the
    // Devices tab's row chip.
    final healthListenable = context.read<FeedHealthTracker>().health;
    return SafeArea(
      child: Column(
        children: [
          ValueListenableBuilder<FeedHealth?>(
            valueListenable: healthListenable,
            builder: (context, health, _) => LiveStatusBar(
              linkState: linkState,
              connectedDeviceName: deviceName,
              sampleRateHz: hub.sampleRateHz,
              health: health,
            ),
          ),
          if (streaming)
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: _showDerivative,
                builder: (context, showDerivative, _) => Column(
                  children: [
                    LiveStats(
                      settings: settings,
                      rig: rig,
                      hub: hub,
                      ctrl: _graphCtrl,
                      showDerivative: showDerivative,
                      healthListenable: healthListenable,
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
            Expanded(
              child: DisconnectedPrompt(
                linkState: linkState,
                deviceName: deviceName,
                onConnect: widget.onGoToDevices,
              ),
            ),
          if (streaming)
            ActionButtons(
              isRecording: recording.sessionInProgress,
              onToggleRecord: _onToggleRecord,
              onTare: _onTare,
              onTareSettings: () => showTareSheet(
                context,
                hub: hub,
                rig: rig,
                settings: settings,
              ),
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
      unit: settings.displayUnit,
      limitWarningsEnabled: settings.limitWarningsEnabled,
      activeChannels: settings.activeChannelIndices,
      showDerivative: showDerivative,
    );
  }
}

// ---------------------------------------------------------------------------
// LiveStatusBar
// ---------------------------------------------------------------------------

/// A pure status readout of the link state: no actions (the prompt below
/// owns the "Connect a device" CTA, and the Devices tab owns transitions in
/// flight). Only the streaming state gets a tinted surface — a neutral strip
/// means "resting or in transition", never an error (disconnected is the
/// app's modal resting state, not a failure).
class LiveStatusBar extends StatelessWidget {
  final BtLinkState linkState;
  final String connectedDeviceName;

  /// The stream's sample rate for the Hz readout next to the RSSI indicator.
  final int sampleRateHz;

  /// The measured feed-health classification (see [deriveFeedHealth]); null
  /// presents as normal (also the case before the first health tick lands).
  final FeedHealth? health;

  const LiveStatusBar({
    super.key,
    required this.linkState,
    required this.connectedDeviceName,
    required this.sampleRateHz,
    this.health,
  });

  void _showHealthDetails(BuildContext context, FeedHealth health) {
    final hub = context.read<DataHub>();
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(health.shortLabel!),
          content: Text(
            health.detail(
              malformedLen: hub.lastMalformedPacketLen,
              lastDataAt: hub.lastDataAt,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (linkState != BtLinkState.streaming) {
      // One line for both idle and in-flight states; the in-flight stage
      // wording comes from btLinkStateLabel, shared with the Devices tab.
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: scheme.surfaceContainerHighest,
        child: Row(
          children: [
            Icon(
              linkState == BtLinkState.idle
                  ? Icons.bluetooth
                  : Icons.bluetooth_searching,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              linkState == BtLinkState.idle
                  ? 'Not connected'
                  : btLinkStateLabel(linkState)!,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }
    final report = health?.worthReporting ?? false;
    final noData = health?.noDataFlowing ?? false;
    final warning = report
        ? Theme.of(context).extension<StatusColors>()!.onConnectedWarning
        : null;
    return GestureDetector(
      onTap: report ? () => _showHealthDetails(context, health!) : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: scheme.primaryContainer,
        child: Row(
          children: [
            Icon(
              Icons.bluetooth_connected,
              size: 18,
              color: scheme.onPrimaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Connected: $connectedDeviceName',
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (report)
                    Row(
                      children: [
                        Icon(Icons.error_outline, size: 14, color: warning!),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            health!.shortLabel!,
                            style: TextStyle(color: warning, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            const _ConnectedRssiIndicator(),
            Text(
              noData ? 'no data' : '$sampleRateHz Hz',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: noData ? scheme.outline : scheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ConnectedRssiIndicator
// ---------------------------------------------------------------------------

/// The connected device's live signal strength in the status bar, sitting
/// left of the sample-rate label. A narrow select on
/// [BleLinkManager.connectedRssi] so the poll's notify rebuilds only this
/// indicator.
class _ConnectedRssiIndicator extends StatelessWidget {
  const _ConnectedRssiIndicator();

  @override
  Widget build(BuildContext context) {
    final rssi = context.select<BleLinkManager, int?>((l) => l.connectedRssi);
    if (rssi == null) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.onPrimaryContainer;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: DefaultTextStyle(
        // Match the sample-rate label; the ambient default style's color is
        // wrong on this tinted primaryContainer surface.
        style:
            Theme.of(context).textTheme.labelSmall?.copyWith(color: color) ??
            TextStyle(color: color),
        child: RssiIndicator(rssi: rssi, color: color, size: 14),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LiveStats
// ---------------------------------------------------------------------------

class LiveStats extends StatelessWidget {
  final AppSettings settings;
  final RigState rig;
  final DataHub hub;

  /// The graph viewport: the Peak row reports the max over this window.
  /// Merged into the rebuild listenable — when the user parks a historical
  /// window, no packets arrive, so only [ctrl] drives the rebuild.
  final GraphController ctrl;
  final bool showDerivative;

  /// The feed-health classification (see [deriveFeedHealth]). When nothing
  /// decodable is arriving (stream stopped/blocked/silent), values gray out
  /// like a gap: the newest "reading" is just the last one seen.
  final ValueListenable<FeedHealth?> healthListenable;

  const LiveStats({
    super.key,
    required this.settings,
    required this.rig,
    required this.hub,
    required this.ctrl,
    this.showDerivative = false,
    required this.healthListenable,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FeedHealth?>(
      valueListenable: healthListenable,
      builder: (context, health, _) => ListenableBuilder(
        listenable: Listenable.merge([hub, ctrl]),
        builder: (context, _) {
          final unit = settings.displayUnit.effective(
            resolveUnitAvailability(
              hub.calibrationFor,
              settings.activeChannelIndices,
            ),
          );

          // A force view shows '—' for an active channel with no cell
          // assigned; point at the fix once. When NO active channel has a
          // cell the whole view bumps to mV/V — no '—' to explain.
          final anyUnassigned =
              unit.isForce &&
              [
                for (int i = 0; i < settings.activeChannels.length; i++)
                  if (settings.activeChannels[i] &&
                      hub.calibrationFor(i).loadCell == null)
                    i,
              ].isNotEmpty;

          // During a live gap (dropped packets) the hub reports held values;
          // gray them out so they read as stale rather than fresh readings.
          // Same when nothing decodable is arriving at all.
          final stale = hub.liveEdgeIsGap || (health?.noDataFlowing ?? false);

          final hasData = hub.totalSamples > 0;
          final clipped = [
            for (int i = 0; i < kAdcChannelCount; i++)
              hasData && ChannelLimits.isClipped(hub.currentRawFor(i)),
          ];

          // The Peak row's window = the graph's viewport.
          final (viewStart, viewEnd) = ctrl.effectiveRange(
            hub.totalSamples,
            hub.oldestSample,
          );

          return Column(
            children: [
              ChannelStatsTable(
                labels: rig.channelTitles,
                activeChannels: settings.activeChannels,
                onToggleChannel: (i) =>
                    settings.setChannelActive(i, !settings.activeChannels[i]),
                unit: unit,
                clipped: clipped,
                rows: [
                  ChannelStatsRow(
                    label: 'Live',
                    values: [
                      for (int i = 0; i < kAdcChannelCount; i++)
                        hub.currentValue(i, unit),
                    ],
                    emphasized: true,
                    stale: stale,
                  ),
                  ChannelStatsRow(
                    label: 'Peak',
                    values: [
                      for (int i = 0; i < kAdcChannelCount; i++)
                        hub.peakValue(i, unit, start: viewStart, end: viewEnd),
                    ],
                  ),
                  ChannelStatsRow(
                    label: 'Tare offset',
                    values: [
                      for (int i = 0; i < kAdcChannelCount; i++)
                        hub.tareOffset(i, unit),
                    ],
                  ),
                  if (showDerivative)
                    ChannelStatsRow(
                      label: 'dF/dt',
                      values: [
                        for (int i = 0; i < kAdcChannelCount; i++)
                          hub.currentDerivative(i, unit),
                      ],
                      stale: stale,
                    ),
                ],
              ),
              if (anyUnassigned)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '— no load cell assigned (Settings → Load cells)',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              // The raw-only verdict: converted units show '—' above; say
              // why, once, in the same style as the load-cell hint.
              if (hub.boardDataStatus != BoardDataStatus.ok)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '— ${hub.boardDataStatus.notice(hub.boardDataDetail)}'
                    ' — raw counts only',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
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
  // Only ever shown while not streaming (the tab shows the live content
  // instead) — a streaming state here would render "Connecting to …".
  const DisconnectedPrompt({
    super.key,
    required this.linkState,
    required this.deviceName,
    required this.onConnect,
  }) : assert(linkState != BtLinkState.streaming);

  final BtLinkState linkState;
  final String deviceName;

  /// "Connect a device" action (idle only): jumps to the Devices tab.
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    // A link transition is in flight: it can take seconds, and only the
    // Devices tab controls it. No action here — a dead Connect button would
    // only beg the question why it's dead. The precise stage label sits in
    // the status bar right above; here the user gets the one thing they
    // care about: it's coming, and to which device.
    if (linkState != BtLinkState.idle) {
      return EmptyPlaceholder(
        icon: Icons.bluetooth_searching,
        title: linkState == BtLinkState.disconnecting
            ? 'Disconnecting from $deviceName…'
            : 'Connecting to $deviceName…',
      );
    }
    return EmptyPlaceholder(
      icon: Icons.bluetooth,
      title: 'No device connected',
      action: FilledButton.tonal(
        onPressed: onConnect,
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

  /// Opens the per-channel tare sheet; disabled alongside TARE while
  /// recording (same reason — a session's tares are frozen at record start).
  final VoidCallback onTareSettings;

  const ActionButtons({
    super.key,
    required this.isRecording,
    required this.onToggleRecord,
    required this.onTare,
    required this.onTareSettings,
  });

  @override
  Widget build(BuildContext context) {
    // Narrow select: rebuilds this row only on taring edges — the hub's
    // per-packet notifies re-run the selector without dirtying the widget.
    final taring = context.select<DataHub, bool>((h) => h.taring);
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
          // TARE and its options read as one control: the outlined ⋮
          // segment hugs the button rather than floating as a third
          // action in the row.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: isRecording ? null : onTare,
                icon: const Icon(Icons.exposure_zero),
                label: Text(taring ? 'TARING' : 'TARE'),
              ),
              const SizedBox(width: 4),
              IconButton.outlined(
                tooltip: 'Tare options',
                onPressed: isRecording ? null : onTareSettings,
                icon: const Icon(Icons.tune),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
