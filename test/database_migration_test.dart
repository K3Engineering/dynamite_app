import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/database.dart';

/// Tests for the database's space-reclaim behavior: SQLite never shrinks the
/// database file on DELETE alone, so [AppDatabase.migration] enables
/// `auto_vacuum = FULL` (and VACUUMs after the dev wipe) to keep the file at
/// the size of its live data instead of its high-water mark.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('database_migration_test');
    AppDatabase.instance = AppDatabase.forTesting(
      NativeDatabase(File('${tmp.path}/test.db')),
    );
  });

  tearDown(() async {
    await AppDatabase.closeInstance();
    await tmp.delete(recursive: true);
  });

  Future<int> pragma(String name) async {
    final row = await AppDatabase.instance
        .customSelect('PRAGMA $name')
        .getSingle();
    return row.data.values.single as int;
  }

  Future<int> newSessionWithChunks(int chunkCount) async {
    final id = await AppDatabase.instance.createSession(
      name: '',
      sampleRate: 1000,
      channelCount: 4,
      channelLabels: '[]',
      tares: '[]',
      calibrationJson: '[]',
      visibleChannels: '[]',
      displayUnit: 'kgf',
      deviceInfoJson: '{}',
      boardMetaJson: null,
      ssnOrigin: 0,
    );
    // Match the live writer's chunk size (~1 s of samples, 16 KiB).
    final chunk = Uint8List(16384);
    for (var i = 0; i < chunkCount; i++) {
      await AppDatabase.instance.insertChunk(id, i, chunk);
    }
    return id;
  }

  test('a fresh database is created with auto_vacuum = FULL', () async {
    expect(await pragma('auto_vacuum'), 1);
  });

  test('deleting a session reclaims its pages instead of growing the '
      'freelist', () async {
    final baseline = await pragma('page_count');

    final id = await newSessionWithChunks(64); // ~1 MiB of chunk data
    final grown = await pragma('page_count');
    expect(grown, greaterThan(baseline + 200));

    await AppDatabase.instance.deleteSession(id);

    expect(await pragma('freelist_count'), 0);
    expect(await pragma('page_count'), lessThan(baseline + 20));
  });
}
