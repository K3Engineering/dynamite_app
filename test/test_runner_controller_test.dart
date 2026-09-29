import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/analysis/metrics.dart';
import 'package:dynamite_app/analysis/plate_series.dart';
import 'package:dynamite_app/analysis/segmentation_cmj.dart';
import 'package:dynamite_app/analysis/test_catalog.dart';
import 'package:dynamite_app/analysis/test_def.dart';
import 'package:dynamite_app/runner/plate_source.dart';
import 'package:dynamite_app/runner/test_recorder.dart';
import 'package:dynamite_app/runner/test_runner_controller.dart';

import 'helpers/synthetic_plate.dart';

/// In-memory [PlateSource] over per-corner kgf arrays; [advance] reveals
/// samples 100 ms at a time, driving the controller's per-tick transitions.
/// [startsAt] shifts the whole index space (like a hub mid-stream history).
class _FakePlateSource implements PlateSource {
  _FakePlateSource(this._corners, {int startsAt = 0}) : _startsAt = startsAt;

  final List<List<double>> _corners; // [tl, tr, bl, br]
  final int _startsAt;
  final ChangeNotifier _notifier = ChangeNotifier();
  int _cursor = 0;

  @override
  int get totalSamples => _startsAt + _cursor;

  @override
  int get oldestSample => _startsAt;

  @override
  PlateReader? read() => PlateReader.fromCornerForce(
    (corner, index) => _corners[corner][index - _startsAt],
    sampleRate: 1000,
  );

  @override
  Listenable get changes => _notifier;

  @override
  bool taring = false;

  @override
  int tareVersion = 0;

  @override
  void requestTare() {
    taring = false;
    tareVersion++;
  }

  int get length => _corners.first.length;

  void advance(int samples) {
    _cursor = math.min(_cursor + samples, length);
    _notifier.notifyListeners();
  }
}

class _FakeRecorder implements TestRecorder {
  final ChangeNotifier _notifier = ChangeNotifier();
  bool _inProgress = false;
  String sessionName = '';

  @override
  bool get inProgress => _inProgress;

  @override
  Listenable get changes => _notifier;

  @override
  TestRecorderStartResult start(String name) {
    _inProgress = true;
    sessionName = name;
    _notifier.notifyListeners();
    return const TestRecorderStarted();
  }

  @override
  Future<TestRecorderStopResult> stop() async {
    _inProgress = false;
    _notifier.notifyListeners();
    return TestRecorderSaved('session-1', sessionName);
  }
}

void main() {
  /// A 1.5 s empty lead-in followed by three scripted jumps, so the controller
  /// can zero, weigh, and capture all three reps. [dips] picks each rep's
  /// countermovement (true = CMJ, false = squat jump).
  _FakePlateSource buildTrace({
    int startsAt = 0,
    List<bool> dips = const [true, true, true],
  }) {
    final corners = <List<double>>[[], [], [], []];
    void addEmpty(int n) {
      for (final c in corners) {
        c.addAll(List.filled(n, 0.0));
      }
    }

    addEmpty(1500);
    for (int rep = 0; rep < dips.length; rep++) {
      final jump = SyntheticCmj(seed: rep + 1, dip: dips[rep]);
      for (int c = 0; c < 4; c++) {
        corners[c].addAll(jump.cornerKgf[c]);
      }
    }
    return _FakePlateSource(corners, startsAt: startsAt);
  }

  Future<void> runToSummary(
    WidgetTester tester,
    TestRunnerController ctrl,
    _FakePlateSource source,
  ) async {
    ctrl.begin();
    for (int i = 0; i < source.length; i += 100) {
      source.advance(100);
      await tester.pump();
    }
    await tester.pump();
  }

  testWidgets('segments three reps and summarizes', (tester) async {
    final source = buildTrace();
    final recorder = _FakeRecorder();
    final ctrl = TestRunnerController(
      test: jumpBatteryTest,
      person: 'Test',
      source: source,
      recorder: recorder,
    );
    addTearDown(ctrl.dispose);
    await runToSummary(tester, ctrl, source);

    expect(ctrl.phase, TestRunnerPhase.summary);
    expect(ctrl.reps, hasLength(3));
    expect(ctrl.bodyWeightKgf, closeTo(80, 0.5));
    for (final rep in ctrl.reps) {
      final height = rep.metric('height_flight');
      expect(height, isNotNull);
      expect(height, greaterThan(0.05));
    }
    // Overlays carry one span set per completed rep.
    expect(ctrl.overlays?.spans, isNotEmpty);
  });

  testWidgets('classifies a mixed CMJ/SJ battery', (tester) async {
    final source = buildTrace(dips: [true, false, true]);
    final ctrl = TestRunnerController(
      test: jumpBatteryTest,
      person: 'Test',
      source: source,
      recorder: _FakeRecorder(),
    );
    addTearDown(ctrl.dispose);
    await runToSummary(tester, ctrl, source);

    expect(ctrl.phase, TestRunnerPhase.summary);
    expect(ctrl.reps, hasLength(3));
    expect(
      [for (final r in ctrl.reps) r.jumpClass],
      [JumpClass.countermovement, JumpClass.squat, JumpClass.countermovement],
    );
    // The squat rep has no eccentric phase and no eccentric span.
    expect(ctrl.reps[1].metric('eccentric_duration'), isNull);
    expect(ctrl.reps[1].phases.spans, hasLength(3));
    final saved = ctrl.result!;
    expect(saved.reps[1].spans, hasLength(3));
    // And the EUR join has both classes to work with.
    expect(eccentricUtilizationRatio(ctrl.reps), isNotNull);
  });

  testWidgets('captures two timed windows back to back', (tester) async {
    // Two 1 s windows over a scripted sway trace: 1.5 s empty lead-in for
    // tare, 1 s of quiet for the stance baseline, then the two windows plus
    // slack.
    const timedDef = TestDef(
      id: 'romberg',
      name: 'Romberg balance screen',
      category: 'Balance',
      description: '',
      mold: TestMold.timedCapture,
      centerPlot: TestCenterPlot.copPlate,
      windows: [
        TestCaptureWindow(label: 'A', durationMs: 1000),
        TestCaptureWindow(label: 'B', durationMs: 1000),
      ],
    );
    final corners = <List<double>>[[], [], [], []];
    for (int i = 0; i < 1500; i++) {
      for (final c in corners) {
        c.add(0.0);
      }
    }
    final sway = SyntheticSway(
      samples: 3000,
      copX: (t) => 0.1 * math.sin(2 * math.pi * t),
      copY: (_) => 0.02,
    );
    final swayCorners = sway.cornerLists();
    for (int c = 0; c < 4; c++) {
      corners[c].addAll(swayCorners[c]);
    }
    final source = _FakePlateSource(corners);
    final ctrl = TestRunnerController(
      test: timedDef,
      person: 'Test',
      source: source,
      recorder: _FakeRecorder(),
    );
    addTearDown(ctrl.dispose);
    await runToSummary(tester, ctrl, source);

    expect(ctrl.phase, TestRunnerPhase.summary);
    expect(ctrl.swayReps, hasLength(2));
    expect(ctrl.swayReps[0].label, 'A');
    expect(ctrl.swayReps[1].label, 'B');
    for (final rep in ctrl.swayReps) {
      expect(rep.end - rep.start, 1000);
      expect(rep.metric('sway_path'), isNotNull);
      expect(rep.ellipse, isNotNull);
    }
    final saved = ctrl.result!;
    expect(saved.testId, 'romberg');
    expect(saved.reps, hasLength(2));
    expect(saved.reps[0].label, 'A');
    expect(saved.reps[0].start, 0);
    expect(saved.reps[0].end - saved.reps[0].start, 1000);
    expect(saved.reps[1].label, 'B');
  });

  testWidgets('persisted phases are session-relative on a shifted source', (
    tester,
  ) async {
    // A source with prehistory (the hub mid-stream): the live phase bounds
    // live in the source's index space, but [TestResult.reps] must index the
    // recording slice, which starts at the source's position at start time.
    final source = buildTrace(startsAt: 4200);
    int? origin;
    final ctrl = TestRunnerController(
      test: jumpBatteryTest,
      person: 'Test',
      source: source,
      recorder: _OriginCapturingRecorder(source, (idx) => origin = idx),
    );
    addTearDown(ctrl.dispose);
    await runToSummary(tester, ctrl, source);

    expect(ctrl.phase, TestRunnerPhase.summary);
    expect(ctrl.reps, hasLength(3));
    expect(origin, isNotNull);
    final saved = ctrl.result!;
    expect(saved.reps, hasLength(3));
    for (int i = 0; i < 3; i++) {
      final live = ctrl.reps[i].phases;
      final persisted = saved.reps[i];
      expect(persisted.start, live.onset - origin!);
      expect(persisted.end, live.end - origin!);
      expect(persisted.start, greaterThanOrEqualTo(0));
      final liveSpans = live.spans;
      expect(persisted.spans, hasLength(liveSpans.length));
      for (int j = 0; j < liveSpans.length; j++) {
        expect(persisted.spans[j].label, liveSpans[j].label);
        expect(persisted.spans[j].start, liveSpans[j].start - origin!);
        expect(persisted.spans[j].end, liveSpans[j].end - origin!);
      }
    }
  });
}

class _OriginCapturingRecorder extends _FakeRecorder {
  _OriginCapturingRecorder(this._source, this._capture);

  final _FakePlateSource _source;
  final void Function(int) _capture;

  @override
  TestRecorderStartResult start(String name) {
    final result = super.start(name);
    _capture(_source.totalSamples);
    return result;
  }
}
