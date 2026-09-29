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
  centerPlot: TestCenterPlot.copPlate,
  instructions: [
    'Mark a walking line so one foot lands fully on the plate each pass.',
    'Walk through at your normal pace, not a stop on the plate.',
    'Keep turning around and walking through; each strike is a pass.',
    'Press stop when you have enough passes.',
  ],
);

const List<TestDef> testCatalog = [jumpBatteryTest, rombergTest, gaitTest];
