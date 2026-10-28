import 'package:meta/meta.dart';

/// Which jump styles a jump-battery run accepts (selected per run on the
/// preflight screen). Coaching names: "concentric" means no countermovement
/// (squat jump), "eccentric" means a dip first (countermovement jump).
enum TestJumpStyle {
  /// Both styles count and are auto-classified.
  auto,

  /// Only no-dip jumps count (a dipped rep is discarded with a coaching
  /// note).
  concentric,

  /// Only dipped jumps count (a no-dip rep is discarded with a coaching
  /// note).
  eccentric,
}

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

/// The measurement family a test belongs to: which segmentation, metric
/// registry, summary table and session reader serve it. The runner and the
/// session detail switch on this — a new family means new cases there.
enum TestFamily {
  /// Jump battery (CMJ/SJ auto-classified).
  jump,

  /// Drop jump (rebound off a box).
  dropJump,

  /// Quiet stance / Romberg windows (sway metrics).
  sway,

  /// Isometric holds against a target band.
  isometric,

  /// Single-leg stance (toe-off gated, sway metrics on the interval).
  singleLeg,

  /// Gait walk-by passes.
  gait,
}

/// What fills the runner screen while a test runs.
enum TestCenterPlot {
  /// Force + CoP traces (jumps).
  forceTrace,

  /// The 2D plate view with the CoP trail (quiet stance).
  copPlate,
}

/// How a rep-count test arms between reps.
enum TestArming {
  /// Athlete stands on the plate; a rep starts when force exits the
  /// body-weight band (default for jump battery).
  stance,

  /// Athlete is off the plate (on a box); a rep starts when they land on
  /// it (drop jump).
  unloaded,
}

/// Target band for an isometric test, as fractions of body weight: hold
/// within `bw × (center ± halfWidth)`.
@immutable
class IsoBandSpec {
  const new({
    required this.centerFractionOfBw,
    required this.halfWidthFraction,
  });

  final double centerFractionOfBw;
  final double halfWidthFraction;
}

/// One fixed-duration window of a [TestMold.timedCapture] test.
@immutable
class TestCaptureWindow {
  const new({required this.label, required this.durationMs});

  /// Condition label shown during capture and stored on the rep (e.g. "Eyes
  /// open").
  final String label;

  final int durationMs;
}

/// Declarative definition of one guided test. The runner interprets these
/// fields, so adding a test is adding data, not a screen.
@immutable
class TestDef {
  const new({
    required this.id,
    required this.name,
    required this.category,
    required this.description,
    required this.mold,
    required this.family,
    this.centerPlot = TestCenterPlot.forceTrace,
    this.arming = TestArming.stance,
    this.repCount,
    this.windows = const [],
    this.isoBand,
    this.instructions = const [],
  }) : assert(
         isoBand == null || family == TestFamily.isometric,
         'isoBand is an isometric-family protocol fact',
       );

  final String id;
  final String name;
  final String category;

  /// One line for the catalog card.
  final String description;

  final TestMold mold;
  final TestFamily family;
  final TestCenterPlot centerPlot;

  /// How the runner arms between reps (rep-count mold).
  final TestArming arming;

  /// Reps to capture for [TestMold.repCount].
  final int? repCount;

  /// Windows to capture for [TestMold.timedCapture], in order.
  final List<TestCaptureWindow> windows;

  /// The hold band for [TestFamily.isometric]: protocol, not measurement, so
  /// it belongs to the definition rather than each capture window.
  final IsoBandSpec? isoBand;

  /// Setup/behaviour lines shown on the pre-flight screen, in order.
  final List<String> instructions;
}
