import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../analysis/events.dart';
import '../analysis/metrics.dart';
import '../analysis/plate_series.dart';
import '../analysis/segmentation_cmj.dart';
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

  /// Recording finalized; metric results are available.
  summary,

  /// The run could not proceed; [TestRunnerController.error] says why.
  failed,
}

/// Drives one guided test from zeroing through segmented reps and a saved
/// session. Owned by the runner screen (a guided run is modal) and the sole
/// caller of the recorder during that run — a manual Live recording in progress
/// refuses the test up front, and an external stop aborts it loudly.
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

  /// Completed reps (valid only; discarded attempts update [lastDiscard]).
  List<CmjRepResult> reps = const [];

  /// The reason the most recent attempt was discarded, or null.
  String? lastDiscard;

  /// Saved session identity, set when the recording finalizes.
  String? sessionId;
  String? sessionName;

  int get targetReps => test.repCount ?? 1;

  /// The finalized analysis, or null before body weight and a valid rep
  /// exist. Bounds are translated into the recording's 0-based index space
  /// here ([TestResult.reps] indexes the session, while the live loop thinks
  /// in the source's space), so the persisted result replays correctly
  /// against a reloaded session.
  TestResult? get result {
    final bw = bodyWeightKgf;
    final origin = _recordOrigin;
    if (bw == null || reps.isEmpty || origin == null) return null;
    return TestResult(
      testId: test.id,
      person: person.trim(),
      bodyWeightKgf: bw,
      reps: [for (final r in reps) r.phases.toTestRep(-origin)],
    );
  }

  bool _started = false;
  bool _stopping = false;
  bool _inTick = false;

  /// True once a stable loaded stance has been seen; the next sustained drop
  /// below body weight starts a rep. Decoupled from the stability check so the
  /// dip itself (which corrupts the trailing window's sigma) doesn't cancel
  /// arming.
  bool _armed = false;
  int _tareVersionBefore = 0;
  int? _repStart;

  /// The source's total-sample count latched at [recorder] start; the
  /// recording's first sample, i.e. the translation between the live
  /// source's index space and the session's (see [result]).
  int? _recordOrigin;

  bool get _running =>
      phase == TestRunnerPhase.readyForRep || phase == TestRunnerPhase.jumping;

  /// Latest total plate force (kgf), or null before data flows.
  double? get liveForceKgf {
    final reader = source.read();
    final total = source.totalSamples;
    if (reader == null || total < 1) return null;
    return reader.weightsAt(total - 1).total;
  }

  /// Phase shading for completed reps plus the live rep preview.
  GraphOverlays? get overlays {
    final reader = source.read();
    if (reader == null) return null;
    final spans = <GraphOverlaySpan>[
      for (final rep in reps)
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
        final ctx = _jumpContext;
        if (ctx != null) {
          final seg = segmentCmj(
            PlateWindow.capture(reader, start, total),
            ctx,
          );
          if (seg is CmjRep) {
            for (final s in seg.phases.spans) {
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
    }
    return spans.isEmpty ? null : GraphOverlays(spans: spans);
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
    final stopResult = await recorder.stop();
    _stopping = false;
    switch (stopResult) {
      case TestRecorderSaved(:final sessionId, :final name):
        this.sessionId = sessionId;
        sessionName = name;
        phase = TestRunnerPhase.summary;
        final sink = onResult;
        final analysis = result;
        if (sink != null && analysis != null) {
          unawaited(sink(sessionId, analysis));
        }
      case TestRecorderNothingRecorded():
        _fail('Nothing was recorded — no data reached the plate.');
      case TestRecorderFailed(:final error):
        _fail('Saving failed: $error');
    }
    notifyListeners();
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
    // A stop we didn't initiate (Live's STOP, a link drop, storage error)
    // leaves the run with a saved session at best.
    if (_running && !_stopping && !recorder.inProgress) {
      phase = TestRunnerPhase.summary;
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
      case TestRunnerPhase.summary:
      case TestRunnerPhase.failed:
        break;
    }
  }

  void _startRecording() {
    final result = recorder.start(_sessionName());
    switch (result) {
      case TestRecorderStarted():
        reps = const [];
        _repStart = null;
        // start() is synchronous and the hub forwards batches from its tail,
        // so this is the first recorded sample's index in the source's space.
        _recordOrigin = source.totalSamples;
        // A usable body-weight baseline was just measured: armed for rep 1.
        _armed = true;
        lastDiscard = null;
        sessionName = _sessionName();
        phase = TestRunnerPhase.readyForRep;
      case TestRecorderRefused(:final reason):
        _fail(reason);
    }
    notifyListeners();
  }

  /// Armed and waiting for the next rep: a stable loaded stance arms the rep,
  /// then the first sustained drop below body weight starts it.
  void _checkOnset() {
    final reader = source.read();
    if (reader == null) return;
    if (!_armed) {
      if (!_stanceStable()) return;
      _armed = true;
      notifyListeners();
    }
    final total = source.totalSamples;
    // Recent window only: a full second can still hold the previous rep's
    // flight zeros, which would read as a spurious onset.
    final from = math.max(
      source.oldestSample,
      total - 300 * reader.sampleRate ~/ 1000,
    );
    final window = PlateWindow.capture(reader, from, total);
    final onset = findSustainedBelow(
      window,
      window.start,
      window.end,
      onsetThresholdKgf(_jumpContext!),
      math.max(1, kJumpParams.onsetSustainMs * reader.sampleRate ~/ 1000),
    );
    if (onset != null) {
      _repStart = onset;
      _armed = false;
      phase = TestRunnerPhase.jumping;
      notifyListeners();
    }
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
    switch (segmentCmj(window, _jumpContext!)) {
      case CmjRep(:final phases):
        _finishRep(window, phases);
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

  void _finishRep(PlateWindow window, CmjPhases phases) {
    final result = CmjRepResult(
      number: reps.length + 1,
      phases: phases,
      metrics: evaluateCmjMetrics(
        window,
        phases,
        CmjContext(bwKgf: bodyWeightKgf!),
      ),
    );
    reps = [...reps, result];
    _repStart = null;
    _armed = false;
    lastDiscard = null;
    if (reps.length >= targetReps) {
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

  @override
  void dispose() {
    source.changes.removeListener(_onChange);
    recorder.changes.removeListener(_onChange);
    // A run abandoned mid-recording must not leave a dangling session.
    if (_running && recorder.inProgress) {
      unawaited(recorder.stop());
    }
    super.dispose();
  }
}
