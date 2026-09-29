import 'test_def.dart';

/// The v1 test catalog. Only the jump battery is wired end to end so far;
/// the rest land as their molds are built out. A catalog of one is honest
/// for a skeleton.
const TestDef jumpBatteryTest = TestDef(
  id: 'jump',
  name: 'Jump battery',
  category: 'Jump',
  description:
      'Maximal jumps, each classified automatically: dip first for a '
      'countermovement jump (CMJ), push straight up for a squat jump (SJ). '
      'Flight time and impulse give jump height two ways.',
  mold: TestMold.repCount,
  family: TestFamily.jump,
  repCount: 3,
  instructions: [
    'Stand still on the plate, feet on the left and right halves.',
    'Jump as high as you can — with a dip (CMJ) or from a still squat (SJ).',
    'Land back on the plate, one jump at a time.',
    'Mix the two styles to compare them (eccentric utilization).',
  ],
);

/// Quiet stance with eyes open then closed, in one recording — the classic
/// Romberg screen. The EC/EO sway ratio is computed at display time.
const TestDef rombergTest = TestDef(
  id: 'romberg',
  name: 'Romberg balance screen',
  category: 'Balance',
  description:
      'Thirty seconds of quiet standing with eyes open, then thirty with '
      'them closed. Sway path, ellipse area, and the eyes-closed penalty.',
  mold: TestMold.timedCapture,
  family: TestFamily.sway,
  centerPlot: TestCenterPlot.copPlate,
  windows: [
    TestCaptureWindow(label: 'Eyes open', durationMs: 30000),
    TestCaptureWindow(label: 'Eyes closed', durationMs: 30000),
  ],
  instructions: [
    'Stand on the plate with feet on the left and right halves.',
    'Arms at your sides, look straight ahead.',
    'Two 30-second windows back to back; close your eyes when told.',
    'Already have your eyes closed when the second window starts.',
  ],
);

/// A walk-by over the plate: one footstrike per pass, segmented live. The
/// two-axis plate view draws each pass's CoP gait line.
const TestDef gaitTest = TestDef(
  id: 'gait',
  name: 'Gait walk-by',
  category: 'Gait',
  description:
      'Walk across the plate several times, one foot fully on it per pass. '
      'Contact time, loading, and the CoP gait line under the foot.',
  mold: TestMold.freePass,
  family: TestFamily.gait,
  centerPlot: TestCenterPlot.copPlate,
  instructions: [
    'Mark a walking line so one foot lands fully on the plate each pass.',
    'Walk through at your normal pace, not a stop on the plate.',
    'Keep turning around and walking through; each strike is a pass.',
    'Press stop when you have enough passes.',
  ],
);

/// Rebound jumps off a box: land on the plate, jump straight back up.
/// Flight time alone gives height (the COM arrives falling, so impulse
/// can't be seeded); contact time and RSI are the point.
const TestDef dropJumpTest = TestDef(
  id: 'drop_jump',
  name: 'Drop jump',
  category: 'Jump',
  description:
      'Step off a box onto the plate and rebound immediately. Contact time '
      'and reactive strength index (height per contact).',
  mold: TestMold.repCount,
  family: TestFamily.dropJump,
  arming: TestArming.unloaded,
  repCount: 3,
  instructions: [
    'Place a sturdy box next to the plate, level with its surface.',
    'Stand on the box. Step off (don\'t jump down), land on the plate.',
    'Rebound as high as you can, as fast as you can.',
    'Step back onto the box between reps.',
  ],
);

/// Push (or pull) and hold: ten seconds inside a band around 1.5× body
/// weight. Steadiness, time in band, and drift.
const TestDef isoPressTest = TestDef(
  id: 'iso_press',
  name: 'Isometric press hold',
  category: 'Isometric',
  description:
      'Press against an immovable setup and hold 1.5× your body weight for '
      'ten seconds, as steadily as you can.',
  mold: TestMold.timedCapture,
  family: TestFamily.isometric,
  windows: [
    TestCaptureWindow(
      label: 'Hold',
      durationMs: 10000,
      eval: TestWindowEval.isometric,
      isoBand: IsoBandSpec(centerFractionOfBw: 1.5, halfWidthFraction: 0.10),
    ),
  ],
  instructions: [
    'Set up so you can press the plate (or handles anchored to it) against a rigid object.',
    'Push until the readout sits in the target band, then hold.',
    'Hold 10 seconds as steadily as you can. Breathe.',
  ],
);

/// Stand on both feet, lift one when ready, and hold. The timer starts at
/// toe-off by itself and stops when the foot comes back down.
const TestDef singleLegTest = TestDef(
  id: 'single_leg',
  name: 'Single-leg stance',
  category: 'Balance',
  description:
      'Lift one foot and balance. The timer runs from toe-off until the '
      'foot comes back down — no stopwatch, no button.',
  mold: TestMold.timedCapture,
  family: TestFamily.singleLeg,
  centerPlot: TestCenterPlot.copPlate,
  windows: [
    TestCaptureWindow(
      label: 'Any leg',
      durationMs: 30000,
      eval: TestWindowEval.singleLeg,
    ),
  ],
  instructions: [
    'Stand on the plate with feet on the left and right halves, one per side.',
    'When ready, lift one foot and hold as still as you can.',
    'The timer stops by itself when the foot touches the plate again.',
  ],
);

const List<TestDef> testCatalog = [
  jumpBatteryTest,
  dropJumpTest,
  rombergTest,
  gaitTest,
  isoPressTest,
  singleLegTest,
];
