import 'package:meta/meta.dart';

/// How a test sequences its captures; the runner picks its state machine from
/// this.
enum TestMold {
  /// N auto-segmented reps (jumps).
  repCount,

  /// Fixed-duration windows in sequence (quiet stance, isometric holds).
  timedCapture,

  /// A continuous stream segmented into passes, stopped by the user (gait).
  freePass,
}

/// What fills the runner screen while a test runs.
enum TestCenterPlot {
  /// Force + CoP traces (jumps).
  forceTrace,

  /// The 2D plate view with the CoP trail (quiet stance).
  copPlate,
}

/// One fixed-duration window of a [TestMold.timedCapture] test.
@immutable
class TestCaptureWindow {
  const TestCaptureWindow({required this.label, required this.durationMs});

  /// Condition label shown during capture and stored on the rep (e.g. "Eyes
  /// open").
  final String label;

  final int durationMs;
}

/// Declarative definition of one guided test. The runner interprets these
/// fields, so adding a test is adding data, not a screen.
@immutable
class TestDef {
  const TestDef({
    required this.id,
    required this.name,
    required this.category,
    required this.description,
    required this.mold,
    this.centerPlot = TestCenterPlot.forceTrace,
    this.repCount,
    this.windows = const [],
    this.instructions = const [],
  });

  final String id;
  final String name;
  final String category;

  /// One line for the catalog card.
  final String description;

  final TestMold mold;
  final TestCenterPlot centerPlot;

  /// Reps to capture for [TestMold.repCount].
  final int? repCount;

  /// Windows to capture for [TestMold.timedCapture], in order.
  final List<TestCaptureWindow> windows;

  /// Setup/behaviour lines shown on the pre-flight screen, in order.
  final List<String> instructions;
}
