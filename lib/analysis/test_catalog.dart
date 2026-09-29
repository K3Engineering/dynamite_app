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

const List<TestDef> testCatalog = [jumpBatteryTest];
