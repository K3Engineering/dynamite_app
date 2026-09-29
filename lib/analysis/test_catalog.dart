import 'test_def.dart';

/// The v1 test catalog. Only the countermovement jump is wired end to end so
/// far; the rest land as their molds are built out. A catalog of one is
/// honest for a skeleton.
const TestDef cmjTest = TestDef(
  id: 'cmj',
  name: 'Countermovement jump',
  category: 'Jump',
  description:
      'Maximal countermovement jumps. Flight time and impulse give jump '
      'height two ways.',
  mold: TestMold.repCount,
  repCount: 3,
  instructions: [
    'Stand still on the plate, feet on the left and right halves.',
    'Dip and jump as high as you can.',
    'Land back on the plate, one jump at a time.',
  ],
);

const List<TestDef> testCatalog = [cmjTest];
