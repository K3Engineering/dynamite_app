import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' show Color;

import '../analysis/events.dart';
import '../analysis/gait.dart';
import '../analysis/metric_eval.dart';
import '../analysis/metrics.dart';
import '../analysis/metrics_isometric.dart';
import '../analysis/metrics_single_leg.dart';
import '../analysis/metrics_sway.dart';
import '../analysis/plate_series.dart';
import '../analysis/result_overlays.dart';
import '../analysis/segmentation_cmj.dart';
import '../analysis/segmentation_dj.dart';
import '../analysis/test_def.dart';
import '../analysis/test_result.dart';
import '../models/graph_overlays.dart';
import 'plate_source.dart';
import 'test_recorder.dart';

/// Persists a finalized test's analysis against its saved session.
typedef TestResultSink =
    Future<void> Function(String sessionId, TestResult result);

/// Where a test run is in its linear flow. Every state does one thing; any
/// surprise is a loud [failed], never a degraded path.
enum TestRunnerPhase {
  /// Waiting for the plate to empty so it can be zeroed.
  awaitingClear,

  /// Zeroing the plate (the hub's one-second tare window).
  taring,

  /// Waiting for a stable loaded stance, which also measures body weight.
  awaitingStance,

  /// Recording; waiting for the next rep to begin.
  readyForRep,

  /// A rep is in progress (onset seen, jump/flight/landing under way).
  jumping,

  /// A fixed-duration window is being captured (timed-capture mold).
  capturing,

  /// Recording finalized; metric results are available.
  summary,

  /// The run could not proceed; [TestRunnerController.error] says why.
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
/// start (Live's STOP, a stream death, a storage auto-stop) is adopted:
/// the saved session still gets its analysis attached.
///
/// Rep detection is offline over the growing window: each hub tick re-segments
/// `[repStart, now]` and finalizes as soon as a complete jump is present. The
/// saved result is later recomputed from the frozen recording, so both agree.
class TestRunnerController extends ChangeNotifier {
  TestRunnerController({
    required this.test,
    required this.person,
    required this.source,
    required this.recorder,
    this.onResult,
  });

  final TestDef test;

  /// Free-text subject label; empty is allowed.
  final String person;

  final PlateSource source;
  final TestRecorder recorder;

  /// Called once when the recording finalizes with valid reps, to persist the
  /// analysis alongside the session. Fire-and-forget: a persistence failure
  /// must not lose the recording.
  final TestResultSink? onResult;

  /// Plate force below this is "empty" (tared to zero plus noise). kgf.
  static const double _emptyPlateKgf = 2.0;

  /// A rep that never produces a jump within this long is discarded.
  static const int _maxJumpMs = 6000;

  TestRunnerPhase phase = TestRunnerPhase.awaitingClear;

  /// Human-readable failure, empty unless [phase] is [failed].
  String error = '';

  /// Body weight measured during the stance phase, kgf.
  double? bodyWeightKgf;
  double _sigmaKgf = 0;

  /// Completed jump reps (rep-count mold; valid only — discarded attempts
  /// update [lastDiscard]).
  List<CmjRepResult> reps = const [];

  /// Completed drop-jump reps (rep-count mold with unloaded arming).
  List<DjRepResult> djReps = const [];

  /// Completed timed windows (timed-capture mold).
  List<SwayRepResult> swayReps = const [];

  /// Completed walk-by passes (free-pass mold).
  List<GaitPassResult> gaitPasses = const [];

  /// Completed isometric holds (timed-capture windows with a target band).
  List<RepEvaluation> isoReps = const [];

  /// Completed single-leg holds (timed-capture windows with toe-off gating).
  List<SlRepResult> slReps = const [];

  /// Persistable reps for the timed/free-pass molds, in capture order and
  /// the live source's index space ([result] shifts them on read). Jump
  /// reps live on [reps] instead, since their spans come from segmentation.
  List<TestRep> _recordedReps = const [];

  /// The reason the most recent attempt was discarded, or null.
  String? lastDiscard;

  /// Saved session identity, set when the recording finalizes.
  String? sessionId;
  String? sessionName;

  int get targetReps => test.repCount ?? 1;

  /// Total valid reps captured so far, across every mold's typed list.
  int get validRepCount =>
      reps.length +
      djReps.length +
      swayReps.length +
      isoReps.length +
      slReps.length +
      gaitPasses.length;

  /// One-shot cue events (beeps); see [TestRunnerCue].
  Stream<TestRunnerCue> get cues => _cues.stream;
  final StreamController<TestRunnerCue> _cues =
      StreamController<TestRunnerCue>.broadcast();

  void _emit(TestRunnerCue cue) {
    if (!_cues.isClosed) _cues.add(cue);
  }

  /// The finalized analysis, or null before body weight and a valid rep
  /// exist. Bounds are translated into the recording's 0-based index space
  /// here ([TestResult.reps] indexes the session, while the live loop thinks
  /// in the source's space), so the persisted result replays correctly
  /// against a reloaded session.
  TestResult? get result {
    final bw = bodyWeightKgf;
    final origin = _recordOrigin;
    if (bw == null || origin == null) return null;
    // Live bounds shift into the recording's 0-based index space.
    final delta = -origin;
    final testReps = switch (test.mold) {
      TestMold.repCount => switch (test.family) {
        TestFamily.dropJump => [
          for (final r in djReps) r.phases.toTestRep(delta),
        ],
        _ => [for (final r in reps) r.phases.toTestRep(delta)],
      },
      // Timed and free-pass molds accumulate their reps as they finalize.
      TestMold.timedCapture ||
      TestMold.freePass => [for (final r in _recordedReps) r.shifted(delta)],
    };
    if (testReps.isEmpty) return null;
    return TestResult(
      testId: test.id,
      person: person.trim(),
      bodyWeightKgf: bw,
      reps: testReps,
    );
  }

  bool _started = false;
  bool _stopping = false;
  bool _inTick = false;

  /// True once the arming condition for the next rep holds: a stable loaded
  /// stance (stance-armed tests) or a quiet empty plate (unloaded-armed).
  /// Exposed so the status strip can say "stand still" vs "jump".
  bool get armed => _armed;
  bool _armed = false;
  int _tareVersionBefore = 0;
  int? _repStart;

  /// Timed-capture progress: which window and where it started.
  int _windowIndex = 0;
  int? _windowStart;

  /// The moment the force first entered the isometric band (sustained), or
  /// null while the athlete is still getting into it: the hold runs from
  /// here, not from the window's nominal start.
  int? _isoEntry;

  /// Free-pass scan pointer into the source (absolute sample index).
  int _scanFrom = 0;

  /// False until the plate has unloaded once after recording start: the
  /// stance baseline itself must not scan as a footstrike.
  bool _gaitStarted = false;

  /// The source's total-sample count latched at [recorder] start; the
  /// recording's first sample, i.e. the translation between the live
  /// source's index space and the session's (see [result]).
  int? _recordOrigin;

  bool get _running =>
      phase == TestRunnerPhase.readyForRep ||
      phase == TestRunnerPhase.jumping ||
      phase == TestRunnerPhase.capturing;

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

  /// Phase shading for completed reps plus the live rep preview, and the CoP
  /// ellipses of completed sway windows.
  GraphOverlays? get overlays {
    final reader = source.read();
    if (reader == null) return null;
    final spans = <GraphOverlaySpan>[
      for (final rep in swayReps)
        GraphOverlaySpan(
          start: rep.eval.start,
          end: rep.eval.end,
          color: kWindowShadeColor,
        ),
      for (final rep in slReps)
        GraphOverlaySpan(
          start: rep.eval.start,
          end: rep.eval.end,
          color: kWindowShadeColor,
        ),
      for (final rep in isoReps)
        GraphOverlaySpan(
          start: rep.start,
          end: rep.end,
          color: kWindowShadeColor,
        ),
      for (final rep in gaitPasses)
        GraphOverlaySpan(
          start: rep.eval.start,
          end: rep.eval.end,
          color: kWindowShadeColor,
        ),
      for (final rep in reps)
        for (final s in rep.phases.spans)
          GraphOverlaySpan(
            start: s.start,
            end: s.end,
            color: cmjPhaseColor(s.label),
          ),
      for (final rep in djReps)
        for (final s in rep.phases.spans)
          GraphOverlaySpan(
            start: s.start,
            end: s.end,
            color: cmjPhaseColor(s.label),
          ),
    ];
    final start = _repStart;
    if (phase == TestRunnerPhase.jumping && start != null) {
      final total = source.totalSamples;
      if (total > start) {
        final bw = bodyWeightKgf;
        if (bw != null) {
          final preview = PlateWindow.capture(reader, start, total);
          final previewSpans = switch (test.family) {
            TestFamily.dropJump => switch (segmentDj(preview, bw)) {
              DjRep(:final phases) => phases.spans,
              DjRejected() => const <PhaseSpan>[],
            },
            _ => switch (segmentCmj(preview, _jumpContext!)) {
              CmjRep(:final phases) => phases.spans,
              CmjRejected() => const <PhaseSpan>[],
            },
          };
          for (final s in previewSpans) {
            spans.add(
              GraphOverlaySpan(
                start: s.start,
                end: s.end,
                color: cmjPhaseColor(s.label),
              ),
            );
          }
        }
      }
    }
    final ellipses = <PlateEllipseOverlay>[
      for (final rep in swayReps)
        if (rep.ellipse case final e?)
          PlateEllipseOverlay(
            cx: e.cx,
            cy: e.cy,
            semiA: e.semiA,
            semiB: e.semiB,
            angleRad: e.angleRad,
            color: const Color(0xFF2196F3),
          ),
      for (final rep in slReps)
        if (rep.ellipse case final e?)
          PlateEllipseOverlay(
            cx: e.cx,
            cy: e.cy,
            semiA: e.semiA,
            semiB: e.semiB,
            angleRad: e.angleRad,
            color: const Color(0xFF9C27B0),
          ),
    ];
    final trails = <PlateTrailOverlay>[
      for (final p in gaitPasses)
        PlateTrailOverlay(points: p.trail, color: gaitTrailColor(p.number)),
    ];
    if (spans.isEmpty && ellipses.isEmpty && trails.isEmpty) return null;
    return GraphOverlays(
      spans: spans,
      plateEllipses: ellipses,
      plateTrails: trails,
    );
  }

  JumpContext? get _jumpContext {
    final bw = bodyWeightKgf;
    if (bw == null) return null;
    return JumpContext(bwKgf: bw, sigmaKgf: _sigmaKgf);
  }

  /// Enter the flow. Refuses loudly when the plate can't be read or a manual
  /// recording already owns the recorder.
  void begin() {
    if (_started) return;
    _started = true;
    if (source.read() == null) {
      _fail(
        'The plate is not fully calibrated — assign a load cell to all four '
        'corners, then try again.',
      );
      return;
    }
    if (recorder.inProgress) {
      _fail('A recording is already running. Stop it before starting a test.');
      return;
    }
    source.changes.addListener(_onChange);
    recorder.changes.addListener(_onChange);
    _tick();
  }

  /// Stop the recording and finalize (the operator's early stop, or the
  /// automatic stop after the last rep).
  Future<void> stopAndFinish() async {
    if (_stopping || !_running) return;
    _stopping = true;
    try {
      switch (await recorder.stop()) {
        case TestRecorderSaved(:final sessionId, :final name):
          _finishWithSaved(sessionId, name);
        case TestRecorderNothingRecorded():
          _fail('Nothing was recorded — no data reached the plate.');
        case TestRecorderFailed(:final error, :final sessionId):
          // Partial save: keep whatever persisted (analysis best-effort),
          // but the failure stays loud.
          if (sessionId != null) _persistResult(sessionId);
          _fail('Saving failed: $error');
        case TestRecorderAlreadyFinalizing():
          // A stop we didn't start was in flight: adopt its outcome.
          await _waitForRecordingEnd();
          _adoptExternalStop();
      }
    } finally {
      _stopping = false;
    }
    notifyListeners();
  }

  /// A saved recording reached summary: attach the analysis and show results.
  void _finishWithSaved(String sessionId, String name) {
    this.sessionId = sessionId;
    sessionName = name;
    phase = TestRunnerPhase.summary;
    _persistResult(sessionId);
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
  void _adoptExternalStop() {
    switch (recorder.lastStop) {
      case TestRecorderSaved(:final sessionId, :final name):
        _finishWithSaved(sessionId, name);
      case TestRecorderNothingRecorded():
        _fail('The recording stopped before any data reached storage.');
      case TestRecorderFailed(:final error, :final sessionId):
        if (sessionId != null) _persistResult(sessionId);
        _fail('Saving failed: $error');
      case TestRecorderAlreadyFinalizing() || null:
        _fail('The recording stopped unexpectedly — check the connection.');
    }
  }

  /// Wait until an in-flight finalization completes (liveness via the
  /// recorder's change notifications, condition re-checked per wake).
  Future<void> _waitForRecordingEnd() async {
    while (recorder.inProgress) {
      final done = Completer<void>();
      void ping() => done.complete();
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
    // auto-stop) finished the recording out from under the run: adopt its
    // outcome — the same path as a self-initiated stop converges to.
    if (_running && !_stopping && !recorder.inProgress) {
      _adoptExternalStop();
      notifyListeners();
      return;
    }
    switch (phase) {
      case TestRunnerPhase.awaitingClear:
        final baseline = _trailingBaseline();
        if (baseline != null && baseline.meanKgf.abs() < _emptyPlateKgf) {
          _tareVersionBefore = source.tareVersion;
          source.requestTare();
          phase = TestRunnerPhase.taring;
          notifyListeners();
        }
      case TestRunnerPhase.taring:
        if (!source.taring && source.tareVersion != _tareVersionBefore) {
          phase = TestRunnerPhase.awaitingStance;
          notifyListeners();
        }
      case TestRunnerPhase.awaitingStance:
        final baseline = _trailingBaseline();
        if (baseline != null && baseline.isUsable) {
          bodyWeightKgf = baseline.meanKgf;
          _sigmaKgf = baseline.sigmaKgf;
          _startRecording();
        }
      case TestRunnerPhase.readyForRep:
        _checkOnset();
      case TestRunnerPhase.jumping:
        _advanceJump();
      case TestRunnerPhase.capturing:
        test.mold == TestMold.freePass ? _advanceGaitScan() : _advanceCapture();
      case TestRunnerPhase.summary:
      case TestRunnerPhase.failed:
        return;
    }
    // The live status strips (countdown, readouts, arming) read the growing
    // data, so repaint every tick. Summary/failed return above — they are
    // static and skip the per-tick rebuild.
    notifyListeners();
  }

  void _startRecording() {
    final result = recorder.start(_sessionName());
    switch (result) {
      case TestRecorderStarted():
        reps = const [];
        djReps = const [];
        swayReps = const [];
        gaitPasses = const [];
        isoReps = const [];
        slReps = const [];
        _recordedReps = const [];
        _repStart = null;
        // start() is synchronous and the hub forwards batches from its tail,
        // so this is the first recorded sample's index in the source's space.
        _recordOrigin = source.totalSamples;
        // A usable body-weight baseline was just measured: stance-armed
        // tests are armed for rep 1. Unloaded arming (drop jump from a box)
        // arms only once the plate goes quiet-empty.
        _armed = test.arming == TestArming.stance;
        lastDiscard = null;
        sessionName = _sessionName();
        switch (test.mold) {
          case TestMold.repCount:
            phase = TestRunnerPhase.readyForRep;
          case TestMold.timedCapture:
            _beginWindow(0);
          case TestMold.freePass:
            _scanFrom = source.totalSamples;
            _gaitStarted = false;
            phase = TestRunnerPhase.capturing;
        }
      case TestRecorderRefused(:final reason):
        _fail(reason);
    }
    notifyListeners();
  }

  /// Armed and waiting for the next rep. Stance-armed: a stable loaded
  /// stance arms, then the first sustained exit from the body-weight band
  /// starts a rep (down = countermovement, up = squat-jump push).
  /// Unloaded-armed: a quiet empty plate arms, then the first sustained
  /// load starts the rep (the drop-jump landing).
  void _checkOnset() {
    final reader = source.read();
    if (reader == null) return;
    final total = source.totalSamples;
    // Recent window only: a full second can still hold the previous rep's
    // flight zeros, which would read as a spurious onset.
    final from = math.max(
      source.oldestSample,
      total - 300 * reader.sampleRate ~/ 1000,
    );
    final window = PlateWindow.capture(reader, from, total);
    if (test.arming == TestArming.unloaded) {
      if (!_armed) {
        if (!_plateUnloaded()) return;
        _armed = true;
        notifyListeners();
      }
      final bw = bodyWeightKgf!;
      final touchdown = findSustainedAbove(
        window,
        window.start,
        window.end,
        kDjParams.loadFraction * bw,
        math.max(1, kDjParams.sustainMs * reader.sampleRate ~/ 1000),
      );
      if (touchdown != null) {
        _repStart = touchdown;
        _armed = false;
        phase = TestRunnerPhase.jumping;
        _emit(TestRunnerCue.repStarted);
        notifyListeners();
      }
      return;
    }
    if (!_armed) {
      if (!_stanceStable()) return;
      _armed = true;
      notifyListeners();
    }
    final (lower, upper) = onsetBandKgf(_jumpContext!);
    final onset = findSustainedOutside(
      window,
      window.start,
      window.end,
      lower,
      upper,
      math.max(1, kJumpParams.onsetSustainMs * reader.sampleRate ~/ 1000),
    );
    if (onset != null) {
      _repStart = onset;
      _armed = false;
      phase = TestRunnerPhase.jumping;
      _emit(TestRunnerCue.repStarted);
      notifyListeners();
    }
  }

  /// A quiet empty plate: the arming condition for unloaded-start tests
  /// (athlete back on the box between drop jumps).
  bool _plateUnloaded() {
    final reader = source.read();
    if (reader == null) return false;
    final total = source.totalSamples;
    final n = 300 * reader.sampleRate ~/ 1000;
    if (total - source.oldestSample < n) return false;
    final window = PlateWindow.capture(reader, total - n, total);
    final baseline = estimateBaseline(window, window.start, window.end);
    return baseline != null && baseline.meanKgf.abs() < _emptyPlateKgf;
  }

  /// A short loaded stance at body weight: the re-arm condition between reps.
  /// Deliberately 300 ms, not the 1 s body-weight window — a rep's dip can
  /// follow the quiet almost immediately, and a long window would still be
  /// contaminated by the dip when the onset check runs.
  bool _stanceStable() {
    final reader = source.read();
    final bw = bodyWeightKgf;
    if (reader == null || bw == null) return false;
    final total = source.totalSamples;
    final n = 300 * reader.sampleRate ~/ 1000;
    if (total - source.oldestSample < n) return false;
    final window = PlateWindow.capture(reader, total - n, total);
    final baseline = estimateBaseline(window, window.start, window.end);
    if (baseline == null) return false;
    return (baseline.meanKgf - bw).abs() < 0.05 * bw &&
        baseline.sigmaKgf < 0.03 * bw;
  }

  /// A rep is under way: re-segment `[repStart, now]`; finalize when a full
  /// jump is present, discard when it never materialises or the athlete walks
  /// off.
  void _advanceJump() {
    final reader = source.read();
    final start = _repStart;
    if (reader == null || start == null || bodyWeightKgf == null) return;
    final total = source.totalSamples;
    if (total - start > _maxJumpMs * reader.sampleRate ~/ 1000) {
      _discard('No jump detected — try again.');
      return;
    }
    final window = PlateWindow.capture(reader, start, total);
    if (test.family == TestFamily.dropJump) {
      switch (segmentDj(window, bodyWeightKgf!)) {
        case DjRep(:final phases):
          _finishDjRep(window, phases);
        case DjRejected(:final reason):
          switch (reason) {
            case DjInvalidReason.noContact:
            case DjInvalidReason.noFlight:
            case DjInvalidReason.incomplete:
              // Still in progress: keep watching.
              break;
            case DjInvalidReason.noRebound:
              _discard('No rebound detected — drop and jump straight back up.');
            case DjInvalidReason.steppedOff:
              _fail('The athlete left the plate mid-jump.');
          }
      }
      return;
    }
    switch (segmentCmj(window, _jumpContext!)) {
      case CmjRep(:final phases, :final jumpClass):
        _finishRep(window, phases, jumpClass);
      case CmjRejected(:final reason):
        switch (reason) {
          case CmjInvalidReason.noFlight:
          case CmjInvalidReason.incomplete:
            // Still in progress (or awaiting the landing): keep watching.
            break;
          case CmjInvalidReason.steppedOff:
            _fail('The athlete left the plate mid-jump.');
        }
    }
  }

  void _finishRep(PlateWindow window, CmjPhases phases, JumpClass jumpClass) {
    reps = [
      ...reps,
      buildCmjRepResult(
        window,
        phases,
        jumpClass,
        CmjContext(bwKgf: bodyWeightKgf!),
        reps.length + 1,
      ),
    ];
    _repStart = null;
    _armed = false;
    _emit(TestRunnerCue.repAccepted);
    if (reps.length >= targetReps) {
      unawaited(stopAndFinish());
    } else {
      phase = TestRunnerPhase.readyForRep;
    }
    notifyListeners();
  }

  void _finishDjRep(PlateWindow window, DjPhases phases) {
    djReps = [...djReps, buildDjRepResult(window, phases, djReps.length + 1)];
    _repStart = null;
    _armed = false;
    _emit(TestRunnerCue.repAccepted);
    if (djReps.length >= targetReps) {
      unawaited(stopAndFinish());
    } else {
      phase = TestRunnerPhase.readyForRep;
    }
    notifyListeners();
  }

  void _discard(String reason) {
    lastDiscard = reason;
    _repStart = null;
    _armed = false;
    phase = TestRunnerPhase.readyForRep;
    _emit(TestRunnerCue.repDiscarded);
    notifyListeners();
  }

  // -- Timed-capture mold --

  /// Status for the status strip during [TestRunnerPhase.capturing]: which
  /// window, its total length, how many whole milliseconds remain, and
  /// whether an isometric hold is still waiting for band entry.
  ({
    int number,
    int count,
    String label,
    int durationMs,
    int remainingMs,
    bool awaitingBand,
  })?
  get captureStatus {
    if (test.mold != TestMold.timedCapture ||
        phase != TestRunnerPhase.capturing) {
      return null;
    }
    final start = _windowStart;
    final reader = source.read();
    if (start == null || reader == null) return null;
    final def = test.windows[_windowIndex];
    // An isometric hold runs from band entry, and the countdown with it.
    final awaiting = def.eval == TestWindowEval.isometric && _isoEntry == null;
    final anchor = awaiting ? start : (_isoEntry ?? start);
    final target = def.durationMs * reader.sampleRate ~/ 1000;
    final remaining = target - (source.totalSamples - anchor);
    return (
      number: _windowIndex + 1,
      count: test.windows.length,
      label: def.label,
      durationMs: def.durationMs,
      remainingMs: math.max(0, remaining * 1000 ~/ reader.sampleRate),
      awaitingBand: awaiting,
    );
  }

  /// Open window [index]: it runs until [_advanceCapture] seals it at its
  /// definition's duration. Windows are back to back — no re-baseline
  /// between them (the subject keeps standing through the transition).
  void _beginWindow(int index) {
    _windowIndex = index;
    _windowStart = source.totalSamples;
    _isoEntry = null;
    phase = TestRunnerPhase.capturing;
    _emit(TestRunnerCue.windowStarted);
    notifyListeners();
  }

  void _advanceCapture() {
    final reader = source.read();
    final start = _windowStart;
    if (reader == null || start == null) return;
    final def = test.windows[_windowIndex];
    final target = def.durationMs * reader.sampleRate ~/ 1000;
    if (source.totalSamples - start < target) return;
    switch (def.eval) {
      case TestWindowEval.sway:
        swayReps = [
          ...swayReps,
          evaluateSwayWindow(
            PlateWindow.capture(reader, start, start + target),
            def.label,
            swayReps.length + 1,
          ),
        ];
        final rep = swayReps.last.eval;
        _recordedReps = [
          ..._recordedReps,
          TestRep(label: rep.label, start: rep.start, end: rep.end),
        ];
        _emit(TestRunnerCue.repAccepted);
      case TestWindowEval.isometric:
        final band = def.isoBand!;
        final ctx = IsoContext.forBw(
          bodyWeightKgf!,
          band.centerFractionOfBw,
          band.halfWidthFraction,
        );
        // The hold runs from the first sustained band entry, not from the
        // window's nominal start — the athlete gets into the press first.
        var entry = _isoEntry;
        if (entry == null) {
          final sustain = 300 * reader.sampleRate ~/ 1000;
          final search = PlateWindow.capture(
            reader,
            start,
            source.totalSamples,
          );
          for (int i = start; i + sustain <= source.totalSamples; i++) {
            bool inside = true;
            for (int k = 0; k < sustain; k++) {
              final f = search.smoothAt(i + k);
              if (f < ctx.bandLowKgf || f > ctx.bandHighKgf) {
                inside = false;
                break;
              }
            }
            if (inside) {
              entry = i;
              _isoEntry = i;
              _emit(TestRunnerCue.bandEntered);
              notifyListeners();
              break;
            }
          }
          if (entry == null) return;
        }
        if (source.totalSamples - entry < target) return;
        final rep = evaluateIsoWindow(
          PlateWindow.capture(reader, entry, entry + target),
          ctx,
          def.label,
          isoReps.length + 1,
        );
        isoReps = [...isoReps, rep];
        _recordedReps = [
          ..._recordedReps,
          TestRep(label: rep.label, start: rep.start, end: rep.end),
        ];
        _emit(TestRunnerCue.repAccepted);
      case TestWindowEval.singleLeg:
        final window = PlateWindow.capture(reader, start, start + target);
        final interval = findSingleLegInterval(window, bwKgf: bodyWeightKgf!);
        if (interval == null) {
          lastDiscard =
              'No single-leg lift detected — the window is discarded.';
          _emit(TestRunnerCue.repDiscarded);
          break;
        }
        final rep = evaluateSlWindow(
          PlateWindow.capture(reader, interval.start, interval.end),
          interval.loadedLeft ? 'Left leg' : 'Right leg',
          slReps.length + 1,
        );
        slReps = [...slReps, rep];
        _recordedReps = [
          ..._recordedReps,
          TestRep(
            label: rep.eval.label,
            start: rep.eval.start,
            end: rep.eval.end,
          ),
        ];
        lastDiscard = null;
        _emit(TestRunnerCue.repAccepted);
    }
    final next = _windowIndex + 1;
    if (next >= test.windows.length) {
      _windowStart = null;
      unawaited(stopAndFinish());
    } else {
      _beginWindow(next);
    }
    notifyListeners();
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

  void _fail(String message) {
    error = message;
    phase = TestRunnerPhase.failed;
    notifyListeners();
  }

  /// The active isometric window's hold band in kgf, or null outside an
  /// isometric capture (for the status strip's aim line).
  ({double low, double high, double center})? get activeBandKgfs {
    if (phase != TestRunnerPhase.capturing) return null;
    final def = test.windows[_windowIndex];
    if (def.eval != TestWindowEval.isometric) return null;
    final bw = bodyWeightKgf;
    if (bw == null) return null;
    final band = def.isoBand!;
    return (
      low: bw * (band.centerFractionOfBw - band.halfWidthFraction),
      high: bw * (band.centerFractionOfBw + band.halfWidthFraction),
      center: bw * band.centerFractionOfBw,
    );
  }

  // -- Free-pass (gait) mold --

  /// Scan forward for completed loading episodes: touchdown over the load
  /// threshold, then the settle back under it. Episodes failing any of
  /// [kGaitParams]'s validity checks are dropped with a note; a
  /// trailing episode without its settle tail is left for the next tick (or
  /// silently dropped when the operator stops).
  void _advanceGaitScan() {
    final reader = source.read();
    final bw = bodyWeightKgf;
    if (reader == null || bw == null) return;
    final total = source.totalSamples;
    if (total <= _scanFrom) return;
    const params = kGaitParams;
    final rate = reader.sampleRate;
    final threshold = params.loadFraction * bw;
    final sustain = math.max(1, params.onsetSustainMs * rate ~/ 1000);
    final settle = params.settleMs * rate ~/ 1000;
    final window = PlateWindow.capture(reader, _scanFrom, total);

    if (!_gaitStarted) {
      // Skip the stance that measured body weight: wait for the first
      // settled unload, then start scanning for footstrikes.
      final off = findSustainedBelow(
        window,
        window.start,
        window.end,
        threshold,
        settle,
      );
      if (off == null) return;
      _scanFrom = off + settle;
      _gaitStarted = true;
      _emit(TestRunnerCue.gaitArmed);
      notifyListeners();
      return;
    }

    final touchdown = findSustainedAbove(
      window,
      window.start,
      window.end,
      threshold,
      sustain,
    );
    if (touchdown == null) {
      // Idle plate: trim the scan window down to the armed tail so an idle
      // walk-by session doesn't rescan an ever-growing window every tick.
      _scanFrom = math.max(_scanFrom + 1, total - sustain);
      return;
    }
    final settleStart = findSustainedBelow(
      window,
      touchdown,
      window.end,
      threshold,
      settle,
    );
    if (settleStart == null) {
      // Contact longer than any footstrike: it's someone standing on the
      // plate. Drop the episode and wait for the unload before scanning on
      // (the same state as at recording start).
      if (total - touchdown > params.maxContactMs * rate ~/ 1000) {
        lastDiscard = 'Pass dropped: a touch or a stand, not a footstrike.';
        _gaitStarted = false;
        _scanFrom = touchdown;
        _emit(TestRunnerCue.repDiscarded);
        notifyListeners();
      }
      // Still in contact (or the tail hasn't arrived yet): next tick.
      return;
    }

    final episodeEnd = settleStart + settle;
    final episode = PlateWindow.capture(reader, touchdown, episodeEnd);
    switch (locateGaitContact(episode, GaitContext(bwKgf: bw))) {
      case GaitPass(:final touchdown, :final toeOff):
        final pass = buildGaitPassResult(
          reader,
          GaitPass(touchdown, toeOff),
          gaitPasses.length + 1,
          GaitContext(bwKgf: bw),
        );
        gaitPasses = [...gaitPasses, pass];
        _recordedReps = [
          ..._recordedReps,
          TestRep(start: pass.eval.start, end: pass.eval.end),
        ];
        lastDiscard = null;
        _emit(TestRunnerCue.repAccepted);
      case GaitRejected(:final reason):
        lastDiscard = switch (reason) {
          GaitInvalidReason.offPlateEdge =>
            'Pass dropped: the foot hit the plate edge.',
          GaitInvalidReason.contactLength =>
            'Pass dropped: a touch or a stand, not a footstrike.',
          GaitInvalidReason.underLoaded =>
            'Pass dropped: not enough weight on the plate.',
        };
        _emit(TestRunnerCue.repDiscarded);
    }
    _scanFrom = episodeEnd;
    notifyListeners();
  }

  @override
  void dispose() {
    source.changes.removeListener(_onChange);
    recorder.changes.removeListener(_onChange);
    // A run abandoned mid-recording must not leave a dangling session.
    if (_running && recorder.inProgress) {
      unawaited(recorder.stop());
    }
    unawaited(_cues.close());
    super.dispose();
  }
}
