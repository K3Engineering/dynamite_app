import 'package:meta/meta.dart';

/// How a test sequences its captures; the runner picks its state machine from
/// this.
enum TestMold {
  /// N auto-segmented reps (jumps).
  repCount,

  /// One fixed-duration capture (quiet stance, isometric holds).
  timedCapture,

  /// A continuous stream segmented into passes, stopped by the user (gait).
  freePass,
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
    this.repCount,
    this.durationMs,
    this.instructions = const [],
  });

  final String id;
  final String name;
  final String category;

  /// One line for the catalog card.
  final String description;

  final TestMold mold;

  /// Reps to capture for [TestMold.repCount].
  final int? repCount;

  /// Capture length for [TestMold.timedCapture].
  final int? durationMs;

  /// Setup/behaviour lines shown on the pre-flight screen, in order.
  final List<String> instructions;
}
