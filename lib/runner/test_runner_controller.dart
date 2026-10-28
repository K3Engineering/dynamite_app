import 'dart:async';

import 'package:flutter/foundation.dart';

import '../analysis/events.dart';
import '../analysis/plate_series.dart';
import '../analysis/result_overlays.dart';
import '../analysis/test_def.dart';
import '../analysis/test_family.dart';
import '../analysis/test_result.dart';
import '../models/graph_overlays.dart';
import 'mold_flow.dart';
import 'plate_source.dart';
import 'test_recorder.dart';

/// Persists a finalized test's analysis against its saved session.
typedef TestResultSink = Future<void> Function(
  String sessionId,
  TestResult result,
);

/// Where a test run is in its *lifecycle*: the prologue that ends in a
/// recording, the recording itself, and its finalization. It deliberately says
/// nothing about what the test measures — that lives in the mold flow, which
/// is what keeps this enum at seven arms instead of the molds multiplying it.
///
/// [stopping] exists so that "the recording is finalizing" is a phase rather
/// than a flag beside one: a rep can only be accepted while the recording is
/// still receiving samples, which makes a rep whose end lies past the recorded
/// length unrepresentable instead of filtered on reload.
enum TestRunnerPhase {
  /// Waiting for the plate to empty so it can be zeroed.
  awaitingClear,

  /// Zeroing the plate (the hub's one-second tare window).
  taring,

  /// Waiting for a stable loaded stance, which also measures body weight.
  awaitingStance,

  /// Recording; the mold flow is capturing.
  recording,

  /// The recording is finalizing; nothing is detected and nothing is added.
  stopping,

  /// Recording finalized; metric results are available.
  summary,

  /// The run could not proceed; [TestRunnerController.error] says why. The
  /// recording of whatever was captured is still finalized and saved.
  failed,
}

/// One-shot events for audible cues; the runner screen turns each into a
/// sound. Emitted once per occurrence, never replayed.
enum TestRunnerCue {
  /// A rep's onset registered (the jump/drop landed on the plate).
  repStarted,

  /// A rep validated and counted.
  repAccepted,

  /// An attempt was rejected ([TestRunnerController.lastDiscard] says why).
  repDiscarded,

  /// The next timed-capture window opened (conditions changed).
  windowStarted,

  /// The isometric hold's force entered the target band (timer runs).
  bandEntered,

  /// The gait scan armed — the stance baseline is past, walking counts now.
  gaitArmed,
}

/// Drives one guided test from zeroing through segmented reps and a saved
/// session. Owned by the runner screen (a guided run is modal) and the sole
/// caller of the recorder during that run — a manual Live recording in
/// progress refuses the test up front, and any stop the controller didn't
/// start (Live's STOP, a stream death, a storage auto-stop) is adopted: the
/// saved session still gets its analysis attached.
///
/// The controller owns exactly two things: the recording's lifecycle (zero,
/// tare, weigh, record, finalize) and the recorder. What happens *during* the
/// recording is a [MoldFlow] — one per [TestMold], constructed at recording
/// start and dropped at its end, so a mold's state can never outlive its run
/// or leak into another mold's.
class TestRunnerController extends ChangeNotifier {
  new({
    required this.test,
    required this.person,
    required this.source,
    required this.recorder,
    this.jumpStyle = TestJumpStyle.auto,
    this.onResult,
  });

  final TestDef test;

  /// Free-text subject label; empty is allowed.
  final String person;

  final PlateSource source;
  final TestRecorder recorder;

  /// Which jump styles count as reps ([TestJumpStyle.auto] = both). Jump
  /// battery only; ignored by other families.
  final TestJumpStyle jumpStyle;

  /// Called once when the recording finalizes with valid reps, to persist the
  /// analysis alongside the session. Fire-and-forget: a persistence failure
  /// must not lose the recording.
  final TestResultSink? onResult;

  TestRunnerPhase phase = TestRunnerPhase.awaitingClear;

  /// Human-readable failure, empty unless [phase] is [failed].
  String error = '';

  /// Body weight measured during the stance phase, kgf.
  double? bodyWeightKgf;
  double _sigmaKgf = 0;

  /// Completed reps, in capture order and the live source's index space
  /// ([result] shifts them on read). Every family and every mold lands here: a
  /// rep is one [EvaluatedRep] regardless of how it was segmented.
  List<EvaluatedRep> reps = const [];

  /// The reason the most recent attempt was discarded, or null.
  String? lastDiscard;

  /// Saved session identity, set when the recording finalizes.
  String? sessionId;
  String? sessionName;

  int get targetReps => test.repCount ?? 1;

  int get validRepCount => reps.length;

  /// One-shot cue events (beeps); see [TestRunnerCue].
  Stream<TestRunnerCue> get cues => _cues.stream;
  final StreamController<TestRunnerCue> _cues =
      StreamController<TestRunnerCue>.broadcast();

  void _emit(TestRunnerCue cue) {
    if (!_cues.isClosed) _cues.add(cue);
  }

  /// [ChangeNotifier.notifyListeners], skipped once disposed: the terminal
  /// transition is async and can resume after the runner screen is gone.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// The finalized analysis, or null before body weight and a valid rep
  /// exist. Bounds are translated into the recording's 0-based index space
  /// here ([TestResult.reps] indexes the session, while the live loop thinks
  /// in the source's space), so the persisted result replays correctly
  /// against a reloaded session.
  TestResult? get result {
    final bw = bodyWeightKgf;
    final origin = _recordOrigin;
    if (bw == null || origin == null || reps.isEmpty) return null;
    return TestResult(
      testId: test.id,
      person: person.trim(),
      bodyWeightKgf: bw,
      reps: [for (final r in reps) r.toTestRep(-origin)],
    );
  }

  bool _started = false;
  bool _inTick = false;

  /// Set by [dispose]. The terminal transition is async (it awaits the
  /// recorder's finalize), so it can resume after the screen has gone; a
  /// notification on a disposed [ChangeNotifier] throws.
  bool _disposed = false;

  /// The mold's state machine, alive exactly while [phase] is [recording].
  MoldFlow? _flow;

  /// The source's total-sample count latched at [recorder] start; the
  /// recording's first sample, i.e. the translation between the live source's
  /// index space and the session's (see [result]).
  int? _recordOrigin;

  int _tareVersionBefore = 0;

  /// True while the recording may still accept reps: [phase] is [recording]
  /// and the mold flow is live.
  bool get _running => phase == TestRunnerPhase.recording;

  /// True when this run has a recording of its own that may still be in
  /// flight: the recording, or the finalize it triggered.
  bool get _ownsRecording => _running || phase == TestRunnerPhase.stopping;

  /// A rep is being segmented right now (rep-count mold only). Delegated like
  /// [armed] and [captureProgress]: the mold says, the controller doesn't
  /// type-test it.
  bool get repInProgress => _flow?.repInProgress ?? false;

  /// True when the next rep's onset will be detected.
  bool get armed => _flow?.armed ?? false;

  /// Timed-capture progress for the status strip, or null outside one.
  CaptureProgress? get captureStatus => _flow?.captureProgress;

  /// The active isometric band as fractions of body weight, for the status
  /// strip's aim line, or null outside an isometric capture.
  ({double low, double high, double center})? get bandFractions =>
      _running ? _flow?.bandKgfs : null;

  /// Latest total plate force (kgf), or null before data flows.
  double? get liveForceKgf {
    final reader = source.read();
    final total = source.totalSamples;
    if (reader == null || total < 1) return null;
    return reader.weightsAt(total - 1).total;
  }

  /// The trailing baseline candidate: stability feedback while awaiting the
  /// stance measurement (force readout plus a stillness hint).
  BaselineStats? get baseline => _trailingBaseline();

  /// Every completed rep's own annotation, plus the in-flight rep's preview.
  /// The preview is the segmentation this tick already ran, so a rebuild never
  /// captures and segments the window again.
  GraphOverlays? get overlays {
    final preview = _flow?.previewOverlays;
    if (reps.isEmpty && preview == null) return null;
    return mergeOverlays([for (final r in reps) r.overlays, ?preview]);
  }

  /// Enter the flow. Refuses loudly when the plate can't be read or a manual
  /// recording already owns the recorder.
  void begin() {
    if (_started) return;
    _started = true;
    if (source.read() == null) {
      _refuse(
        'The plate is not fully calibrated — assign a load cell to all four '
        'corners, then try again.',
      );
      return;
    }
    if (recorder.inProgress) {
      _refuse(
        'A recording is already running. Stop it before starting a test.',
      );
      return;
    }
    source.changes.addListener(_onChange);
    recorder.changes.addListener(_onChange);
    _tick();
  }

  /// Stop the recording and finalize (the operator's early stop, or the
  /// automatic stop after the last rep). Refused unless a recording is live:
  /// summary, failed and a stop already in flight are no-ops.
  Future<void> stopAndFinish() => _finalize(null);

  /// Abandon the current rep and end the run. A live recording is still
  /// finalized and saved, so the reps captured before the failure stay
  /// reviewable; this is the only path that ends a run on the athlete's
  /// behaviour rather than the operator's word.
  void _fail(String message) => unawaited(_finalize(message));

  /// End a run that never got a recording (the plate can't be read, the
  /// recorder refused, a manual recording owns it): there is nothing to stop
  /// and nothing to save.
  void _refuse(String message) {
    error = message;
    phase = TestRunnerPhase.failed;
    _notify();
  }

  /// The single terminal transition: latch [phase] to [stopping], stop the
  /// recording, and surface its fate as [summary] or [failed] with [failure]
  /// as the reason. Persisting the analysis is unconditional — the recording
  /// exists either way, and dropping the reps captured before a failure is the
  /// silent degradation this controller exists to avoid.
  Future<void> _finalize(String? failure) async {
    if (!_running) return;
    phase = TestRunnerPhase.stopping;
    _flow = null;
    _notify();
    switch (await recorder.stop()) {
      case TestRecorderSaved(:final sessionId, :final name):
        _finishWithSaved(sessionId, name, failure: failure);
      case TestRecorderNothingRecorded():
        _finishFailed('Nothing was recorded — no data reached the plate.');
      case TestRecorderFailed(:final error, :final sessionId):
        // Partial save: keep whatever persisted, but the failure stays loud.
        if (sessionId != null) _persistResult(sessionId);
        _finishFailed(
          failure == null
              ? 'Saving failed: $error'
              : '$failure — saving failed: $error',
        );
      case TestRecorderAlreadyFinalizing():
        // A stop we didn't start raced ours: adopt its latched outcome.
        await _waitForRecordingEnd();
        _adoptExternalStop(failure);
    }
    _notify();
  }

  /// A saved recording reached a terminal phase: attach the analysis and show
  /// [failure] when the run failed for a reason other than storage.
  void _finishWithSaved(String sessionId, String name, {String? failure}) {
    this.sessionId = sessionId;
    sessionName = name;
    _persistResult(sessionId);
    if (failure == null) {
      phase = TestRunnerPhase.summary;
    } else {
      error = failure;
      phase = TestRunnerPhase.failed;
    }
  }

  /// A run that ended without a usable recording; [message] replaces any
  /// earlier note because the storage outcome is the newer fact.
  void _finishFailed(String message) {
    error = message;
    phase = TestRunnerPhase.failed;
  }

  void _persistResult(String sessionId) {
    final sink = onResult;
    final analysis = result;
    if (sink != null && analysis != null) {
      unawaited(sink(sessionId, analysis));
    }
  }

  /// A stop the controller didn't start (Live's STOP, a stream death, a
  /// storage auto-stop): the recording's fate is latched on the recorder —
  /// adopt it. A saved session still gets its analysis attached; anything
  /// else is a loud failure, never a silent summary.
  void _adoptExternalStop([String? failure]) {
    switch (recorder.lastStop) {
      case TestRecorderSaved(:final sessionId, :final name):
        _finishWithSaved(sessionId, name, failure: failure);
      case TestRecorderNothingRecorded():
        _finishFailed('The recording stopped before any data reached storage.');
      case TestRecorderFailed(:final error, :final sessionId):
        if (sessionId != null) _persistResult(sessionId);
        _finishFailed('Saving failed: $error');
      case TestRecorderAlreadyFinalizing() || null:
        _finishFailed(
          'The recording stopped unexpectedly — check the connection.',
        );
    }
  }

  /// Wait until an in-flight finalization completes (liveness via the
  /// recorder's change notifications, condition re-checked per wake). The
  /// listener can fire more than once before it is removed, so the completer
  /// is completed at most once.
  Future<void> _waitForRecordingEnd() async {
    while (recorder.inProgress) {
      final done = Completer<void>();
      void ping() => done.isCompleted ? null : done.complete();
      recorder.changes.addListener(ping);
      try {
        await done.future;
      } finally {
        recorder.changes.removeListener(ping);
      }
    }
  }

  void _onChange() => _tick();

  void _tick() {
    // Recorder/source notifications can fire re-entrantly from inside a tick
    // (e.g. starting a recording notifies); drop those, the outer tick is
    // authoritative.
    if (_inTick) return;
    _inTick = true;
    try {
      _tickInner();
    } finally {
      _inTick = false;
    }
  }

  void _tickInner() {
    // A stop we didn't initiate (Live's STOP, a link drop, a storage
    // auto-stop) began under the run: no more samples will be recorded, so
    // adopt its outcome — the same path as a self-initiated stop converges to.
    // Checked on [TestRecorder.acceptingData], not `inProgress`: the latter
    // stays true through the finalize flush, which is exactly the window in
    // which detection must not run.
    if (_running && !recorder.acceptingData) {
      phase = TestRunnerPhase.stopping;
      _flow = null;
      _notify();
      unawaited(
        _waitForRecordingEnd().then((_) {
          _adoptExternalStop();
          _notify();
        }),
      );
      return;
    }
    switch (phase) {
      case TestRunnerPhase.awaitingClear:
        final baseline = _trailingBaseline();
        if (baseline != null && baseline.meanKgf.abs() < kEmptyPlateKgf) {
          _tareVersionBefore = source.tareVersion;
          source.requestTare();
          phase = TestRunnerPhase.taring;
          _notify();
        }
      case TestRunnerPhase.taring:
        if (!source.taring && source.tareVersion != _tareVersionBefore) {
          phase = TestRunnerPhase.awaitingStance;
          _notify();
        }
      case TestRunnerPhase.awaitingStance:
        final baseline = _trailingBaseline();
        if (baseline != null && baseline.isUsable) {
          bodyWeightKgf = baseline.meanKgf;
          _sigmaKgf = baseline.sigmaKgf;
          _startRecording();
        }
      case TestRunnerPhase.recording:
        _tickMold();
      // Detection cannot run while the recording finalizes: a rep accepted
      // here would have an end past the recorded length.
      case TestRunnerPhase.stopping:
      case TestRunnerPhase.summary:
      case TestRunnerPhase.failed:
        return;
    }
    // The live status strips read the growing data, so repaint every tick. The
    // terminal phases return above — they are static and skip the rebuild.
    _notify();
  }

  void _startRecording() {
    final result = recorder.start(_sessionName());
    switch (result) {
      case TestRecorderStarted():
        reps = const [];
        lastDiscard = null;
        sessionName = _sessionName();
        // start() is synchronous and the hub forwards batches from its tail,
        // so this is the first recorded sample's index in the source's space.
        _recordOrigin = source.totalSamples;
        _flow = flowFor(
          test,
          jumpStyle: jumpStyle,
          totalSamples: source.totalSamples,
        );
        phase = TestRunnerPhase.recording;
      case TestRecorderRefused(:final reason):
        _refuse(reason);
    }
    _notify();
  }

  /// One tick of the mold's own state machine, applied to this run.
  void _tickMold() {
    final flow = _flow;
    final reader = source.read();
    final bw = bodyWeightKgf;
    if (flow == null || reader == null || bw == null) return;
    final events = flow.tick(
      MoldTick(
        reader: reader,
        totalSamples: source.totalSamples,
        oldestSample: source.oldestSample,
        bwKgf: bw,
        sigmaKgf: _sigmaKgf,
        nextNumber: reps.length + 1,
      ),
    );
    for (final event in events) {
      switch (event) {
        case RepAccepted(:final rep):
          reps = [...reps, rep];
          lastDiscard = null;
          _emit(TestRunnerCue.repAccepted);
        case RepDiscarded(:final reason):
          lastDiscard = reason;
          _emit(TestRunnerCue.repDiscarded);
        case RepStarted():
          _emit(TestRunnerCue.repStarted);
        case WindowStarted():
          _emit(TestRunnerCue.windowStarted);
        case BandEntered():
          _emit(TestRunnerCue.bandEntered);
        case GaitArmed():
          _emit(TestRunnerCue.gaitArmed);
        case RunFailed(:final message):
          _fail(message);
          return;
        case MoldCompleted():
          unawaited(stopAndFinish());
          return;
      }
    }
    // The battery is full and the recording's tail has run out.
    final stop = flow.stopAfterSample;
    if (stop != null && source.totalSamples >= stop) {
      unawaited(stopAndFinish());
    }
  }

  String _sessionName() =>
      person.trim().isEmpty ? test.name : '${test.name} — ${person.trim()}';

  BaselineStats? _trailingBaseline() {
    final reader = source.read();
    if (reader == null) return null;
    final total = source.totalSamples;
    if (total - source.oldestSample < kBaselineMinSamples) return null;
    final window = PlateWindow.capture(
      reader,
      total - kBaselineMinSamples,
      total,
    );
    return estimateBaseline(window, window.start, window.end);
  }

  @override
  void dispose() {
    _disposed = true;
    source.changes.removeListener(_onChange);
    recorder.changes.removeListener(_onChange);
    // A run abandoned mid-recording must not leave a dangling session. A
    // recording that is already finalizing ([_ownsRecording] but no longer
    // accepting data) is left alone: its own stop is in flight.
    if (_ownsRecording && recorder.acceptingData) {
      unawaited(recorder.stop());
    }
    unawaited(_cues.close());
    super.dispose();
  }
}
