import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/session_id.dart';

/// Session ids (session_id.dart): fixed-width timestamp + random suffix —
/// lexical order is chronological order, uniqueness is the suffix's job.
void main() {
  final shape = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-[a-z0-9]{4}$');

  test('matches the fixed-width layout at the example instant', () {
    final id = newSessionId(
      at: DateTime(2026, 8, 28, 14, 30, 12, 345),
      random: Random(7),
    );
    expect(id, matches(shape));
    expect(id, startsWith('2026-08-28T14-30-12-'));
  });

  test('pads every field to its width', () {
    final id = newSessionId(at: DateTime(2027, 1, 2, 3, 4, 5, 6));
    expect(id, startsWith('2027-01-02T03-04-05-'));
  });

  test('lexical order is chronological order', () {
    final rng = Random(1);
    final instants = [
      DateTime(2025, 12, 31, 23, 59, 58),
      DateTime(2025, 12, 31, 23, 59, 59),
      DateTime(2026, 1, 1, 0, 0, 0),
      DateTime(2026, 8, 28, 14, 30, 12),
      DateTime(2026, 8, 28, 14, 30, 13),
      DateTime(2027, 2, 3, 4, 5, 6),
    ];
    final ids = [for (final t in instants) newSessionId(at: t, random: rng)];
    final sorted = List.of(ids)..sort();
    expect(sorted, ids);
  });

  test('same-second creates get distinct ids', () {
    final at = DateTime(2026, 8, 28, 14, 30, 12);
    final ids = {for (int i = 0; i < 100; i++) newSessionId(at: at)};
    expect(ids.length, 100);
  });

  group('sessionIdCreatedAt', () {
    test('round-trips the encoded wall clock', () {
      final at = DateTime(2026, 8, 28, 14, 30, 12);
      expect(sessionIdCreatedAt(newSessionId(at: at)), at);
      expect(
        sessionIdCreatedAt('2027-01-02T03-04-05-x7f2'),
        DateTime(2027, 1, 2, 3, 4, 5),
      );
    });

    test('throws on anything not exactly the id shape', () {
      for (final bad in [
        'junk',
        '2026-08-28T14-30-12', // no suffix
        '2026-08-28T14:30:12-zzzz', // colons
        '2026-8-28T14-30-12-zzzz', // unpadded
        '2026-08-28T14-30-12-ZZZ!', // outside the suffix alphabet
      ]) {
        expect(() => sessionIdCreatedAt(bad), throwsFormatException);
      }
    });
  });
}
