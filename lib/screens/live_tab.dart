import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';
import '../models/analysis_pane.dart';
import '../models/board_calibration.dart';
import '../models/channel_limits.dart';
import '../models/derived_channel.dart';
import '../models/display_unit.dart';

import '../models/bt_scan.dart';
import '../models/device_profile.dart';
import '../models/graph_data_source.dart';
import '../services/ble_link_manager.dart';
import '../services/data_hub.dart';
import '../services/feed_health_tracker.dart';
import '../models/feed_health.dart';
import '../models/hub_event.dart';
import '../widgets/analysis_pane_bar.dart';
import '../widgets/feed_health_text.dart';
import '../services/monitor_pause.dart';
import '../services/recording_controller.dart';
import '../services/rig_state.dart';
import '../widgets/bt_icon.dart';
import '../widgets/channel_stats_table.dart';
import '../widgets/firmware_update_notice.dart';
import '../widgets/tare_sheet.dart';
import '../widgets/session_flows.dart';
import '../widgets/empty_placeholder.dart';
import '../widgets/graph_components.dart';
import '../widgets/rssi_indicator.dart';
import '../widgets/snackbars.dart';
import '../status_colors.dart';
import '../utils/format.dart';
import 'firmware_update_screen.dart';

// ---------------------------------------------------------------------------
// LiveTab
// ---------------------------------------------------------------------------

class LiveTab extends StatefulWidget {
  const LiveTab({
    super.key,
    required this.onGoToDevices,
    required this.onGoToSettings,
  });

  /// The idle prompt's "Connect a device" action; the shell owns the tab index.
  final VoidCallback onGoToDevices;

  /// The empty-math-family placeholder's "Set up math channels" action; the
  /// shell owns the tab index.
  final VoidCallback onGoToSettings;

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<LiveTab> {
  // Live window floor: 20 s at 1 kHz (a UI anchor, not read from the device).
  final GraphController _graphCtrl = GraphController(minLiveSpan: 20 * 1000);

  /// The analysis pane slot's selection; a notifier so switching panes
  /// doesn't rebuild the whole tab.
  final ValueNotifier<AnalysisPaneSelection> _analysisPane = ValueNotifier(
    const AnalysisPaneSelection(),
  );

  /// App-lifetime hub, captured for listener registration only.
  DataHub? _hub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // read (not watch): the hub notifies per packet, which must not rebuild
    // this. App-lifetime singleton, so the identity check fires once.
    final hub = context.read<DataHub>();
    if (_hub != hub) {
      _hub?.removeEventListener(_onHubEvent);
      _hub = hub;
      hub.addEventListener(_onHubEvent);
    }
  }

  /// A hub reset means the previous trace is gone: reset the viewport so a
  /// stale pan/zoom window can't be clamped against an empty buffer.
  void _onHubEvent(HubEvent event) {
    if (event is HubCleared) _graphCtrl.reset();
  }

  @override
  void dispose() {
    _hub?.removeEventListener(_onHubEvent);
    _analysisPane.dispose();
    _graphCtrl.dispose();
    super.dispose();
  }

  void _onTare() {
    // A session freezes tares at record start; refuse re-zeroing mid-recording.
    if (context.read<RecordingController>().sessionInProgress) {
      showErrorSnackBar(
        ScaffoldMessenger.of(context),
        'Stop recording to tare',
      );
      return;
    }
    context.read<DataHub>().requestTare();
  }

  void _onTogglePause() {
    final pause = context.read<MonitorPause>();
    pause.paused ? pause.resume() : pause.pause();
  }

  Future<void> _onToggleRecord() async {
    final recording = context.read<RecordingController>();

    if (recording.sessionInProgress) {
      final result = await recording.stopSession();

      if (!mounted) return;

      switch (result) {
        // Only a cleanly saved session is announced; errors surface via the
        // shell.
        case StopSessionSaved(:final sessionId, :final name):
          showNoticeSnackBar(
            ScaffoldMessenger.of(context),
            'Session saved',
            action: SnackBarAction(
              label: 'Name it',
              onPressed: () => _showRenameDialog(sessionId, name),
            ),
          );
        case StopSessionNothingRecorded() ||
            StopSessionFailed() ||
            StopSessionRefused():
          // Refused is unreachable here (the toggle only stops while in
          // progress).
          break;
      }
    } else {
      final settings = context.read<AppSettings>();
      final hub = context.read<DataHub>();
      final result = recording.startSession(
        channelLabels: context.read<RigState>().channelTitles,
        // Sessions record raw hardware channels only; derived channels are
        // recomputable display-side at review time.
        visibleChannels: settings.activeChannels.sublist(0, kAdcChannelCount),
        // The unit the instrument is drawing, as the export's default.
        displayUnit: settings.displayUnit.effective(hub.unitAvailability),
      );

      switch (result) {
        case StartSessionOk() || StartSessionBusy():
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
    // Availability changes only on calibration edges, so this select is cheap.
    final availability = context.select<DataHub, UnitAvailability>(
      (h) => h.unitAvailability,
    );
    final unit = settings.displayUnit.effective(availability);
    // Rebind on tare edges: the display maps bake offsets in at bind time.
    context.select<DataHub, int>((h) => h.tareVersion);
    // Narrow selects: the link manager notifies per RSSI poll.
    final linkState = context.select<BleLinkManager, BtLinkState>(
      (l) => l.linkState,
    );
    final streaming = linkState == BtLinkState.streaming;
    final deviceName = context.select<BleLinkManager, String>(
      (l) => l.connectedDeviceName,
    );
    final recording = context.watch<RecordingController>();
    final monitorPause = context.watch<MonitorPause>();
    final rig = context.watch<RigState>();
    // read (not watch): LiveStats/graph subscribe to the hub themselves.
    final hub = context.read<DataHub>();
    final invalidBoardDetail = context.select<DataHub, String?>(
      (h) => switch (h.boardCalibration) {
        InvalidBoardCalibration(:final detail) => detail,
        _ => null,
      },
    );
    // Subscribed so a math-profile change flips the CTA without a stream edge.
    final mathChannelCount = context.select<DataHub, int>(
      (h) => h.derivedChannels.length,
    );

    // The on-screen family's channels (see [AppSettings.channelFamily]):
    // [tableIds] for the stats table (inactive included, greyed),
    // [graphIds] for the graphs (active only).
    final tableIds = [
      for (int i = 0; i < hub.channelCount; i++)
        if (settings.channelFamily.includes(i)) i,
    ];
    final graphIds = [
      for (final i in tableIds)
        if (settings.activeChannels[i]) i,
    ];
    final showMathCta =
        settings.channelFamily == ChannelFamily.math && mathChannelCount == 0;

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
              firmwareNotice: FirmwareUpdateNotice(
                onReview: () =>
                    openFirmwareUpdate(context, onDone: widget.onGoToDevices),
              ),
            ),
          ),
          if (invalidBoardDetail != null)
            BoardFaultBanner(detail: invalidBoardDetail),
          if (streaming && showMathCta)
            // The Math family selected with no math channels configured:
            // the dead end gets a way out.
            Expanded(
              child: EmptyPlaceholder(
                icon: Icons.calculate_outlined,
                title: 'No math channels configured',
                hint: 'Set up the rig\'s math channels to use this view',
                action: FilledButton(
                  onPressed: widget.onGoToSettings,
                  child: const Text('Set up math channels'),
                ),
              ),
            )
          else if (streaming)
            Expanded(
              child: ValueListenableBuilder<AnalysisPaneSelection>(
                valueListenable: _analysisPane,
                builder: (context, analysis, _) => Column(
                  children: [
                    LiveStats(
                      settings: settings,
                      rig: rig,
                      hub: hub,
                      channelIds: tableIds,
                      ctrl: _graphCtrl,
                      unit: unit,
                      showDerivative:
                          analysis.kind == AnalysisPaneKind.derivative,
                      healthListenable: healthListenable,
                    ),
                    Expanded(
                      child: _buildGraphArea(hub, unit, graphIds, analysis),
                    ),
                    AnalysisPaneBar(
                      selection: analysis,
                      onChanged: (s) => _analysisPane.value = s,
                      channelLabels: _channelLabels(rig, hub),
                      mathProfile: hub.mathProfile,
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
              sessionStartTime: recording.sessionStartTime,
              isPaused: monitorPause.paused,
              onToggleRecord: _onToggleRecord,
              onTogglePause: _onTogglePause,
              onTare: _onTare,
              onTareSettings: () => showTareSheet(
                context,
                hub: hub,
                rig: rig,
                settings: settings,
                unit: unit,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGraphArea(
    DataHub hub,
    DisplayUnit unit,
    List<int> activeChannels,
    AnalysisPaneSelection analysis,
  ) {
    return GraphWorkspace(
      data: hub,
      ctrl: _graphCtrl,
      unit: unit,
      activeChannels: activeChannels,
      analysis: analysis,
    );
  }

  /// Display label per channel id: the rig's hardware titles, then the
  /// derived channels' minted labels (see `derived_channel.dart`).
  static List<String> _channelLabels(RigState rig, DataHub hub) => [
    ...rig.channelTitles,
    for (final d in hub.derivedChannels) d.label,
  ];
}

// ---------------------------------------------------------------------------
// LiveStatusBar
// ---------------------------------------------------------------------------

/// A pure status readout of the link state.
@visibleForTesting
class LiveStatusBar extends StatelessWidget {
  final BtLinkState linkState;
  final String connectedDeviceName;

  /// The stream's sample rate.
  final int sampleRateHz;

  /// The feed-health classification; null (not streaming) presents as normal.
  final FeedHealth? health;

  /// The firmware-update notice line shown under the connected label; null
  /// (the tests' default) hides it. Built by [LiveTab] from
  /// [FirmwareUpdateService] so this widget stays a pure readout.
  final Widget? firmwareNotice;

  const LiveStatusBar({
    super.key,
    required this.linkState,
    required this.connectedDeviceName,
    required this.sampleRateHz,
    this.health,
    this.firmwareNotice,
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
    final bar = GestureDetector(
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
                        Icon(Icons.error_outline, size: 14, color: warning),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            health!.shortLabel!,
                            style: TextStyle(color: warning, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ?firmwareNotice,
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
    if (!report) return bar;
    return Semantics(
      button: true,
      label: 'Connection health',
      hint: 'Double-tap for details',
      child: bar,
    );
  }
}

// ---------------------------------------------------------------------------
// _ConnectedRssiIndicator
// ---------------------------------------------------------------------------

/// The connected device's live signal strength; a narrow select so RSSI polls
/// rebuild only this indicator.
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

@visibleForTesting
class LiveStats extends StatelessWidget {
  final AppSettings settings;
  final RigState rig;
  final DataHub hub;

  /// The channel ids the table shows: the on-screen family's channels,
  /// inactive included greyed (see [AppSettings.channelFamily]).
  final List<int> channelIds;

  /// The graph viewport; the Peak row reports the max over this window.
  final GraphController ctrl;

  /// The unit the instrument draws in, resolved by [LiveTab].
  final DisplayUnit unit;
  final bool showDerivative;

  /// The feed-health classification; when nothing decodable arrives, values
  /// gray out like a gap.
  final ValueListenable<FeedHealth?> healthListenable;

  const LiveStats({
    super.key,
    required this.settings,
    required this.rig,
    required this.hub,
    required this.channelIds,
    required this.ctrl,
    required this.unit,
    this.showDerivative = false,
    required this.healthListenable,
  });

  @override
  Widget build(BuildContext context) {
    final labels = _LiveTabState._channelLabels(rig, hub);
    return ValueListenableBuilder<FeedHealth?>(
      valueListenable: healthListenable,
      builder: (context, health, _) => ListenableBuilder(
        listenable: Listenable.merge([hub, ctrl]),
        builder: (context, _) {
          // A force view shows '—' for an active channel with no cell; point at
          // the fix once.
          final anyUnassigned =
              unit.isForce &&
              [
                for (final i in channelIds)
                  if (!isDerivedChannelId(i) &&
                      settings.activeChannels[i] &&
                      hub.calibrationFor(i).loadCell == null)
                    i,
              ].isNotEmpty;

          // A live gap or no data flowing grays values out as stale.
          final stale = hub.liveEdgeIsGap || (health?.noDataFlowing ?? false);

          final hasData = hub.totalSamples > 0;
          // Derived channels have no ADC rail of their own.
          final clipped = [
            for (final i in channelIds)
              !isDerivedChannelId(i) &&
                  hasData &&
                  ChannelLimits.isClipped(hub.currentRawFor(i)),
          ];

          final (viewStart, viewEnd) = ctrl.effectiveRange(
            hub.totalSamples,
            hub.oldestSample,
          );

          return Column(
            children: [
              ChannelStatsTable(
                labels: [for (final i in channelIds) labels[i]],
                activeChannels: [
                  for (final i in channelIds) settings.activeChannels[i],
                ],
                onToggleChannel: (pos) {
                  final i = channelIds[pos];
                  unawaited(
                    settings.setChannelActive(i, !settings.activeChannels[i]),
                  );
                },
                unit: unit,
                clipped: clipped,
                rows: [
                  ChannelStatsRow(
                    label: 'Live',
                    values: [
                      for (final i in channelIds) hub.currentValue(i, unit),
                    ],
                    emphasized: true,
                    stale: stale,
                  ),
                  ChannelStatsRow(
                    label: 'Peak',
                    values: [
                      for (final i in channelIds)
                        hub.peakValue(i, unit, start: viewStart, end: viewEnd),
                    ],
                  ),
                  ChannelStatsRow(
                    label: 'Tare offset',
                    values: [
                      for (final i in channelIds) hub.tareOffset(i, unit),
                    ],
                  ),
                  if (settings.showDebugLiveValues) ...[
                    ChannelStatsRow(
                      label: 'AC RMS (4 s)',
                      // Sigma about the trailing 4-second mean, in raw space,
                      // through the diff map. A real load step in the window
                      // reads as noise: a wiggle meter, not a spec.
                      values: [
                        for (final i in channelIds)
                          switch (hub.windowedStdDev(
                            i,
                            hub.totalSamples - 4 * hub.sampleRateHz,
                            hub.totalSamples,
                          )) {
                            final sigma? =>
                              hub
                                  .seriesConverterFor(i)
                                  .diffMap(unit)
                                  ?.call(sigma),
                            null => null,
                          },
                      ],
                      stale: stale,
                    ),
                  ],
                  if (showDerivative)
                    ChannelStatsRow(
                      label: 'dF/dt',
                      values: [
                        for (final i in channelIds)
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
                    '— no load cell assigned (Settings › Load cells)',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              // Bound blends refuse electrical units (see
              // [GraphSeriesQueries.isForceOnlyBlend]): they show '—' with
              // no other explanation, so name them once.
              if ([
                    for (final i in channelIds)
                      if (settings.activeChannels[i] &&
                          hub.isForceOnlyBlend(i, unit))
                        labels[i],
                  ]
                  case final forceOnly when forceOnly.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '— ${forceOnly.join(', ')}: force-only — select a force '
                    'unit to show',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              // Say why converted units show '—', once.
              if (switch (hub.boardCalibration) {
                    UnprovisionedBoardCalibration() =>
                      'no board data — unit not provisioned',
                    InvalidBoardCalibration() => 'board data invalid',
                    _ => null,
                  }
                  case final notice?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '— $notice — raw counts only',
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
// BoardFaultBanner
// ---------------------------------------------------------------------------

/// Banner for an unreadable board calibration; the device streams raw counts
/// underneath.
class BoardFaultBanner extends StatelessWidget {
  const BoardFaultBanner({super.key, required this.detail});

  /// The parser's reason.
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Calibration data unreadable — contact support.\n$detail',
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DisconnectedPrompt
// ---------------------------------------------------------------------------

class DisconnectedPrompt extends StatelessWidget {
  const DisconnectedPrompt({
    super.key,
    required this.linkState,
    required this.deviceName,
    required this.onConnect,
  }) : assert(linkState != BtLinkState.streaming);

  final BtLinkState linkState;
  final String deviceName;

  /// "Connect a device" action (idle only).
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
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
      action: FilledButton(
        onPressed: onConnect,
        child: const Text('Connect a device'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ActionButtons
// ---------------------------------------------------------------------------

class ActionButtons extends StatelessWidget {
  static const _splitLeft = RoundedRectangleBorder(
    borderRadius: BorderRadius.horizontal(
      left: Radius.circular(20),
      right: Radius.circular(4),
    ),
  );
  static const _splitRight = RoundedRectangleBorder(
    borderRadius: BorderRadius.horizontal(
      left: Radius.circular(4),
      right: Radius.circular(20),
    ),
  );

  final bool isRecording;

  /// The recording's start instant for the elapsed caption; null renders a
  /// static 'Recording' caption (the finalization window).
  final DateTime? sessionStartTime;

  /// The monitoring pause: incoming samples are being discarded and the
  /// buffer is frozen (see `MonitorPause`).
  final bool isPaused;

  final VoidCallback onToggleRecord;
  final VoidCallback onTogglePause;
  final VoidCallback onTare;

  /// Opens the per-channel tare sheet; disabled while recording like TARE.
  final VoidCallback onTareSettings;

  const ActionButtons({
    super.key,
    required this.isRecording,
    required this.isPaused,
    required this.onToggleRecord,
    required this.onTogglePause,
    required this.onTare,
    required this.onTareSettings,
    this.sessionStartTime,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final status = Theme.of(context).extension<StatusColors>()!;
    final taring = context.select<DataHub, bool>((h) => h.taring);
    final startTime = sessionStartTime;
    // Pause and recording are mutually exclusive: either discards data a
    // session promised to keep. The disabled state (not a snackbar) is the
    // refusal — the loud mode control explains why the row is half-dead.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ModeControl(
            tooltip: isPaused ? 'Resume monitoring' : 'Pause monitoring',
            icon: Icon(isPaused ? Icons.play_arrow : Icons.pause),
            caption: Text(isPaused ? 'Paused' : 'Monitoring'),
            onPressed: isRecording ? null : onTogglePause,
            outlined: !isPaused,
            backgroundColor: isPaused ? status.warningContainer : null,
            foregroundColor: isPaused ? status.onWarningContainer : null,
          ),
          _ModeControl(
            tooltip: isRecording ? 'Stop recording' : 'Start recording',
            icon: Icon(isRecording ? Icons.stop : Icons.fiber_manual_record),
            caption: isRecording && startTime != null
                ? _RecordingElapsedText(startTime: startTime)
                : Text(isRecording ? 'Recording' : 'Record'),
            onPressed: isPaused ? null : onToggleRecord,
            backgroundColor: isRecording ? cs.error : null,
            foregroundColor: isRecording ? cs.onError : null,
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: isRecording || isPaused ? null : onTare,
                icon: const Icon(Icons.exposure_zero),
                label: Text(taring ? 'TARING' : 'TARE'),
                style: OutlinedButton.styleFrom(shape: _splitLeft),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: 'Tare options',
                child: OutlinedButton(
                  onPressed: isRecording || isPaused ? null : onTareSettings,
                  style: OutlinedButton.styleFrom(shape: _splitRight),
                  child: const Icon(Icons.tune),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One toggle-style mode control of the action row: the icon grants the
/// action, the caption names the current state. Mode controls (record,
/// monitor pause) use this; momentary actions (TARE) stay plain buttons.
/// Loud states (recording in flight, monitoring paused) paint filled with
/// [backgroundColor]; the mutual exclusion guarantees a loud control is
/// never the disabled one, so styled buttons need no disabled tokens.
class _ModeControl extends StatelessWidget {
  const _ModeControl({
    required this.tooltip,
    required this.icon,
    required this.caption,
    required this.onPressed,
    this.outlined = false,
    this.backgroundColor,
    this.foregroundColor,
  });

  /// The full verb+object phrase ('Pause monitoring'); also the semantics
  /// label. Tooltips show even when the button is disabled.
  final String tooltip;
  final Widget icon;
  final Widget caption;
  final VoidCallback? onPressed;

  /// Quiet presentation (monitoring running normally); loud states are
  /// filled via [backgroundColor]/[foregroundColor].
  final bool outlined;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final captionStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final button = outlined
        ? IconButton.outlined(
            onPressed: onPressed,
            tooltip: tooltip,
            icon: icon,
          )
        : IconButton.filled(
            onPressed: onPressed,
            tooltip: tooltip,
            icon: icon,
            style: backgroundColor == null
                ? null
                : IconButton.styleFrom(
                    backgroundColor: backgroundColor,
                    foregroundColor: foregroundColor,
                  ),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        DefaultTextStyle(
          style: captionStyle ?? const TextStyle(),
          child: caption,
        ),
      ],
    );
  }
}

/// The recording control's live `mm:ss` caption; rebuilds only when the
/// whole second changes.
class _RecordingElapsedText extends StatefulWidget {
  const _RecordingElapsedText({required this.startTime});

  final DateTime startTime;

  @override
  State<_RecordingElapsedText> createState() => _RecordingElapsedTextState();
}

class _RecordingElapsedTextState extends State<_RecordingElapsedText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _elapsed = DateTime.now().difference(widget.startTime);
    _ticker = createTicker((_) {
      final whole = Duration(
        seconds: DateTime.now().difference(widget.startTime).inSeconds,
      );
      if (whole != _elapsed) setState(() => _elapsed = whole);
    })..start();
  }

  @override
  void didUpdateWidget(covariant _RecordingElapsedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startTime != widget.startTime) {
      _elapsed = DateTime.now().difference(widget.startTime);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(formatElapsedClock(_elapsed));
}
