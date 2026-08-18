import 'dart:typed_data';

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
        displayUnit: 'kgf',
        deviceInfoJson: '{}',
        createdAt: createdAt,
      )
      .then(
        (id) => AppDatabase.instance
            .completeSession(id, sampleCount: 0, durationMs: 0)
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

    test(
      'recency stays primary: an older row never outranks a newer one',
      () async {
        final t = DateTime(2026, 7, 29, 12);
        final newerId = await newSession(t.add(const Duration(hours: 1)));
        final olderId = await newSession(t);

        final rows = await AppDatabase.instance.watchAllSessions().first;
        expect(rows.map((r) => r.id), [newerId, olderId]);
      },
    );
  });

  group('watchSessionByteSizes', () {
    test('sums chunk blob lengths per session', () async {
      final id = await newSession(DateTime(2026, 7, 29, 12));
      await AppDatabase.instance.insertChunk(id, 0, Uint8List(100));
      await AppDatabase.instance.insertChunk(id, 1, Uint8List(50));

      final sizes = await AppDatabase.instance.watchSessionByteSizes().first;
      expect(sizes[id], 150);
    });

    test('sessions without chunks are absent, not zero', () async {
      final id = await newSession(DateTime(2026, 7, 29, 12));

      final sizes = await AppDatabase.instance.watchSessionByteSizes().first;
      expect(sizes.containsKey(id), isFalse);
    });

    test('re-emits when a chunk lands', () async {
      final id = await newSession(DateTime(2026, 7, 29, 12));
      final stream = AppDatabase.instance.watchSessionByteSizes();

      // Skip the initial (empty) emission, then the insert must produce one.
      final next = stream.skip(1).first;
      await AppDatabase.instance.insertChunk(id, 0, Uint8List(7));
      expect((await next)[id], 7);
    });
  });

  test('databaseFileBytes is a positive multiple of the page size', () async {
    final bytes = await AppDatabase.instance.databaseFileBytes();
    expect(bytes, greaterThan(0));
    expect(bytes % 4096, 0);
  });
}
