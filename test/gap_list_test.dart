import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/gap_list.dart';

void main() {
  group('GapList', () {
    test('empty list contains nothing', () {
      final g = GapList();
      expect(g.isEmpty, isTrue);
      expect(g.contains(0), isFalse);
      expect(g.contains(-1), isFalse);
      expect(g.rangesIn(0, 100), isEmpty);
    });

    test('contains honors half-open bounds', () {
      final g = GapList()..append(10, 20);
      expect(g.contains(9), isFalse);
      expect(g.contains(10), isTrue);
      expect(g.contains(19), isTrue);
      expect(g.contains(20), isFalse);
    });

    test('contains with multiple ranges (binary search)', () {
      final g = GapList()
        ..append(10, 20)
        ..append(30, 40)
        ..append(50, 60);
      for (final i in [10, 15, 19, 30, 39, 50, 59]) {
        expect(g.contains(i), isTrue, reason: '$i should be in a gap');
      }
      for (final i in [0, 9, 20, 25, 29, 40, 45, 49, 60, 100]) {
        expect(g.contains(i), isFalse, reason: '$i should not be in a gap');
      }
    });

    test('append merges with the trailing range', () {
      final g = GapList()
        ..append(10, 20)
        ..append(20, 30) // adjacent: merge
        ..append(40, 50); // disjoint: new range
      expect(g.rangesIn(0, 100).toList(), [(10, 30), (40, 50)]);
    });

    test('append ignores empty ranges', () {
      final g = GapList()..append(10, 10);
      expect(g.isEmpty, isTrue);
    });

    test('rangesIn clamps overlapping ranges', () {
      final g = GapList()
        ..append(10, 20)
        ..append(30, 40);
      expect(g.rangesIn(15, 35).toList(), [(15, 20), (30, 35)]);
      expect(g.rangesIn(20, 30).toList(), isEmpty);
      expect(g.rangesIn(0, 5).toList(), isEmpty);
      expect(g.rangesIn(40, 100).toList(), isEmpty);
    });

    test('pruneBefore drops and clamps ranges', () {
      final g = GapList()
        ..append(10, 20)
        ..append(30, 40)
        ..append(50, 60);
      g.pruneBefore(35); // drops [10,20), clamps [30,40) to [35,40)
      expect(g.rangesIn(0, 100).toList(), [(35, 40), (50, 60)]);
      g.pruneBefore(0); // no-op
      expect(g.rangesIn(0, 100).toList(), [(35, 40), (50, 60)]);
      g.pruneBefore(100); // drops everything
      expect(g.isEmpty, isTrue);
    });

    test('append still works after pruneBefore', () {
      final g = GapList()..append(10, 20);
      g.pruneBefore(100);
      g.append(150, 160);
      expect(g.rangesIn(0, 200).toList(), [(150, 160)]);
    });

    test('JSON round-trip', () {
      final g = GapList()
        ..append(10, 20)
        ..append(30, 40);
      expect(g.toJson(), '[[10,20],[30,40]]');
      final parsed = GapList.fromJson(g.toJson());
      expect(parsed.rangesIn(0, 100).toList(), [(10, 20), (30, 40)]);
      expect(GapList.fromJson('[]').isEmpty, isTrue);
      expect(GapList.fromJson('garbage').isEmpty, isTrue);
    });
  });
}
