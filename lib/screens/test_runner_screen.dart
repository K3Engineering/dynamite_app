import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../analysis/test_def.dart';
import '../analysis/test_result.dart';
import '../models/analysis_pane.dart';
import '../models/display_unit.dart';
import '../models/session_catalog.dart';
import '../runner/plate_source.dart';
import '../runner/test_recorder.dart';
import '../runner/test_runner_controller.dart';
import '../services/app_settings.dart';
import '../services/data_hub.dart';
import '../services/recording_controller.dart';
import '../services/rig_state.dart';
import '../services/session_store.dart';
import '../widgets/graph_components.dart';
import '../widgets/metrics_table.dart';
import 'session_detail_screen.dart';

/// Runs one guided test: zero the plate, measure a stable stance, then record
/// auto-segmented reps and show their metrics.
class TestRunnerScreen extends StatefulWidget {
  const TestRunnerScreen({super.key, required this.def, required this.person});

  final TestDef def;
  final String person;

  @override
  State<TestRunnerScreen> createState() => _TestRunnerScreenState();
}

class _TestRunnerScreenState extends State<TestRunnerScreen> {
  late final TestRunnerController _ctrl;
  final GraphController _graph = GraphController(minLiveSpan: 10 * 1000);
  late final DataHub _hub;
  late final StreamSubscription<TestRunnerCue> _cueSub;

  @override
  void initState() {
    super.initState();
    _hub = context.read<DataHub>();
    _ctrl = TestRunnerController(
      test: widget.def,
      person: widget.person,
      source: DataHubPlateSource(_hub),
      recorder: RecordingTestRecorder(
        recording: context.read<RecordingController>(),
        rig: context.read<RigState>(),
        settings: context.read<AppSettings>(),
      ),
      onResult: _persistResult,
    );
    _cueSub = _ctrl.cues.listen(_onCue);
    _ctrl.begin();
  }

  /// Audible feedback for transitions the athlete can't watch for (window
  /// changes during an eyes-closed window, rep accepted/discarded).
  void _onCue(TestRunnerCue cue) {
    unawaited(
      SystemSound.play(switch (cue) {
        TestRunnerCue.repDiscarded => SystemSoundType.alert,
        _ => SystemSoundType.click,
      }),
    );
  }

  /// Attach the analysis to the just-saved session. Best-effort: the recording
  /// is already safe, so a persistence failure is logged, not surfaced.
  Future<void> _persistResult(String sessionId, TestResult result) async {
    try {
      await SessionStore.instance.setSessionTestResult(sessionId, result);
    } catch (error) {
      debugPrint('Failed to attach test analysis to $sessionId: $error');
    }
  }

  @override
  void dispose() {
    unawaited(_cueSub.cancel());
    _ctrl.dispose();
    _graph.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.def.name)),
      body: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => switch (_ctrl.phase) {
          TestRunnerPhase.awaitingClear => _PromptPanel(
            icon: Icons.pan_tool_alt,
            title: 'Step off the plate',
            subtitle: 'The plate will be zeroed once it is empty.',
            readout: _forceReadout(),
          ),
          TestRunnerPhase.taring => const _PromptPanel(
            icon: Icons.exposure_zero,
            title: 'Zeroing the plate…',
            subtitle: 'Stand clear for a second.',
            busy: true,
          ),
          TestRunnerPhase.awaitingStance => _PromptPanel(
            icon: Icons.accessibility_new,
            title: 'Step on and stand still',
            subtitle: _stanceHint(),
            readout: _forceReadout(),
          ),
          TestRunnerPhase.readyForRep ||
          TestRunnerPhase.jumping ||
          TestRunnerPhase.capturing => _buildRunning(context),
          TestRunnerPhase.summary => _buildSummary(context),
          TestRunnerPhase.failed => _buildFailed(context),
        },
      ),
    );
  }

  /// Why the stance measurement isn't done yet (or that it is running).
  String _stanceHint() {
    final b = _ctrl.baseline;
    if (b == null) return 'Waiting for plate data…';
    if (b.meanKgf.abs() < 5) return 'Step fully onto the plate.';
    if (!b.isStable) return 'Too much movement — hold still.';
    return 'Measuring your body weight…';
  }

  Widget _buildRunning(BuildContext context) {
    final profile = _hub.mathProfile;
    // Reaching this phase means the controller's plate probe succeeded,
    // which entails a plate profile (see [PlateReader.tryForData]).
    return Column(
      children: [
        switch (widget.def.mold) {
          TestMold.timedCapture => _CaptureStatus(ctrl: _ctrl),
          TestMold.freePass => _FreePassStatus(ctrl: _ctrl),
          _ => _RepStatus(ctrl: _ctrl),
        },
        Expanded(
          child: GraphWorkspace(
            data: _hub,
            ctrl: _graph,
            unit: DisplayUnit.kgf,
            // The plate basis as line traces: total force on the force
            // graph, CoP x/y auto-split to the unitless coords graph; the
            // rep-phase overlays shade both.
            activeChannels: [
              profile.plateTotalId!,
              profile.plateXId!,
              profile.plateYId!,
            ],
            overlays: _ctrl.overlays,
            analysis: switch (widget.def.centerPlot) {
              TestCenterPlot.copPlate => const AnalysisPaneSelection(
                kind: AnalysisPaneKind.plate,
              ),
              TestCenterPlot.forceTrace => const AnalysisPaneSelection(),
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _ctrl.stopAndFinish,
            icon: const Icon(Icons.stop),
            label: const Text('Stop and save'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSummary(BuildContext context) {
    final theme = Theme.of(context);
    final bw = _ctrl.bodyWeightKgf;
    final count = _ctrl.validRepCount;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 40,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 8),
        Text(
          _ctrl.sessionName ?? widget.def.name,
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        if (bw != null)
          Text(
            'Body weight ${bw.toStringAsFixed(1)} kgf · '
            '$count rep${count == 1 ? '' : 's'}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        const SizedBox(height: 20),
        if (count == 0)
          const Text('No valid reps were captured.')
        else
          switch (widget.def.family) {
            TestFamily.sway => MetricsTable.sway(reps: _ctrl.swayReps),
            TestFamily.isometric => MetricsTable.isometric(reps: _ctrl.isoReps),
            TestFamily.singleLeg => MetricsTable.singleLeg(reps: _ctrl.slReps),
            TestFamily.gait => MetricsTable.gait(reps: _ctrl.gaitPasses),
            TestFamily.dropJump => MetricsTable.dropJump(reps: _ctrl.djReps),
            _ => MetricsTable.jump(reps: _ctrl.reps),
          },
        const SizedBox(height: 32),
        if (_ctrl.sessionId != null) ...[
          FilledButton.icon(
            onPressed: _openSession,
            icon: const Icon(Icons.insights),
            label: const Text('View saved session'),
          ),
          const SizedBox(height: 12),
        ],
        FilledButton.tonal(
          onPressed: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
          child: const Text('Done'),
        ),
      ],
    );
  }

  /// Jump from the summary to the just-saved session's detail page. Falls
  /// back to simply leaving the flow if the catalog hasn't republished the
  /// fresh entry yet.
  Future<void> _openSession() async {
    final id = _ctrl.sessionId;
    if (id == null) return;
    try {
      final store = SessionStore.instance;
      await store.ensureCatalogLoaded();
      if (store.catalog.value case SessionCatalogReady(:final catalog)) {
        final summary = catalog.session(id);
        if (summary != null && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SessionDetailScreen(session: summary),
            ),
          );
          return;
        }
      }
    } catch (_) {
      // The catalog failing shouldn't strand the user in the runner.
    }
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Widget _buildFailed(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
        const SizedBox(height: 12),
        Text(
          _ctrl.error,
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
          child: const Text('Done'),
        ),
      ],
    );
  }

  String? _forceReadout() {
    final f = _ctrl.liveForceKgf;
    return f == null ? null : '${f.toStringAsFixed(1)} kgf';
  }
}

/// The recording-phase status strip: what to do now (armed vs re-arming),
/// rep progress, the last discard reason, and the completed reps' heights.
class _RepStatus extends StatelessWidget {
  const _RepStatus({required this.ctrl});

  final TestRunnerController ctrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = switch (ctrl.test.family) {
      TestFamily.dropJump => ctrl.djReps.length,
      _ => ctrl.reps.length,
    };
    final height = switch (ctrl.test.family) {
      TestFamily.dropJump =>
        ctrl.djReps.isEmpty ? null : ctrl.djReps.last.metric('height_flight'),
      _ => ctrl.reps.isEmpty ? null : ctrl.reps.last.metric('height_flight'),
    };
    final jumping = ctrl.phase == TestRunnerPhase.jumping;
    final isDj = ctrl.test.family == TestFamily.dropJump;
    final String callToAction;
    if (jumping) {
      callToAction = 'Rep in progress…';
    } else if (!ctrl.armed) {
      // The onset check only runs once the arming condition holds — a jump
      // before that would be silently missed, so say so.
      callToAction = isDj ? 'Step back onto the box…' : 'Stand still…';
    } else {
      callToAction = isDj ? 'Drop and rebound' : 'Jump!';
    }
    return Container(
      width: double.infinity,
      color: theme.colorScheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            callToAction,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          Text(
            'Rep ${done + 1} of ${ctrl.targetReps}',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          if (height != null)
            Text(
              'Last: ${height.toStringAsFixed(3)} m',
              style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
            ),
          if (ctrl.lastDiscard case final reason?)
            Text(reason, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ),
    );
  }
}

/// The timed-capture status strip: which window and the countdown. Doubles
/// as the instruction when the next window has a different condition label.
class _CaptureStatus extends StatelessWidget {
  const _CaptureStatus({required this.ctrl});

  final TestRunnerController ctrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = ctrl.captureStatus;
    final label = status == null
        ? 'Done'
        : 'Window ${status.number} of ${status.count}'
              '${status.label.isEmpty ? '' : ' — ${status.label}'}';
    final remaining = status == null
        ? null
        : (status.remainingMs / 1000).toStringAsFixed(0);
    final singleLeg = ctrl.test.windows.any(
      (w) => w.eval == TestWindowEval.singleLeg,
    );
    return Container(
      width: double.infinity,
      color: theme.colorScheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          if (singleLeg)
            Text(
              'Lift one foot and hold — the timer detects toe-off and '
              'touch-down by itself.',
              style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
            ),
          if (ctrl.activeBandKgfs case final band?)
            Text(
              'Aim ${band.low.toStringAsFixed(0)}–${band.high.toStringAsFixed(0)} kgf'
              '${ctrl.liveForceKgf == null ? '' : ' — now ${ctrl.liveForceKgf!.toStringAsFixed(0)} kgf'}'
              '${status != null && status.awaitingBand ? ' — push into the band to start' : ''}',
              style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
            ),
          if (status != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: status.durationMs == 0
                        ? 0
                        : 1 - status.remainingMs / status.durationMs,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '$remaining s',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The free-pass (gait) status strip: the call to action, the pass count,
/// and the last dropped pass's reason.
class _FreePassStatus extends StatelessWidget {
  const _FreePassStatus({required this.ctrl});

  final TestRunnerController ctrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final passes = ctrl.gaitPasses.length;
    return Container(
      width: double.infinity,
      color: theme.colorScheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Walk through the plate',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          Text(
            '$passes pass${passes == 1 ? '' : 'es'} — press "Stop and save" '
            'when you have enough',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          if (ctrl.lastDiscard case final reason?)
            Text(reason, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ),
    );
  }
}

/// A full-screen instruction step for the pre-capture phases.
class _PromptPanel extends StatelessWidget {
  const _PromptPanel({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.busy = false,
    this.readout,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool busy;
  final String? readout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (busy) ...[
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
            ],
            if (readout != null) ...[
              const SizedBox(height: 24),
              Text(
                readout!,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
