import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/database.dart';

/// Tests for [AppDatabase.watchAllSessions]' ordering: newest first, with a
/// deterministic tiebreak. createdAt is stored at one-second resolution, so
/// sessions created within the same second (rapid stop/start) tie on it —
/// SQLite guarantees no order among ties, and the reactive stream re-emits
/// on every table change, so untiebroken rows could swap under the user.
/// The id column (monotonic with insertion) makes the order total.
void main() {
  Future<int> newSession(DateTime createdAt) => AppDatabase.instance
      .createSession(
        name: '',
        sampleRate: 1000,
        channelCount: 4,
        channelLabels: '[]',
        tares: '[]',
        calibrationJson: '[]',
        visibleChannels: '[]',
        createdAt: createdAt,
      )
      .then(
        (id) => AppDatabase.instance
            .completeSession(id, sampleCount: 0, durationMs: 0, peaksRaw: '[]')
            .then((_) => id),
      );

  setUp(() {
    AppDatabase.instance = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(AppDatabase.closeInstance);

  group('watchAllSessions ordering', () {
    test('sessions created in the same second order newest-id first', () async {
      final t = DateTime(2026, 7, 29, 12);
      final id1 = await newSession(t);
      final id2 = await newSession(t);

      final rows = await AppDatabase.instance.watchAllSessions().first;
      expect(rows.map((r) => r.id), [id2, id1]);
    });

    test('recency stays primary: an older row never outranks a newer one', () async {
      final t = DateTime(2026, 7, 29, 12);
      final newerId = await newSession(t.add(const Duration(hours: 1)));
      final olderId = await newSession(t);

      final rows = await AppDatabase.instance.watchAllSessions().first;
      expect(rows.map((r) => r.id), [newerId, olderId]);
    });
  });
}
