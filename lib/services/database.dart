import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// Table for recorded measurement sessions.
class Sessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  IntColumn get sampleRate => integer().withDefault(const Constant(1000))();
  IntColumn get channelCount => integer().withDefault(const Constant(2))();
  TextColumn get channelLabels =>
      text().withDefault(const Constant('["Load Cell 1","Load Cell 2"]'))();
  TextColumn get tares => text().withDefault(const Constant('[]'))();
  RealColumn get peakForceRaw => real().withDefault(const Constant(0.0))();
  IntColumn get peakForceChannel => integer().withDefault(const Constant(0))();
  RealColumn get calibrationSlope =>
      real().withDefault(const Constant(0.0001117587))();
  IntColumn get calibrationOffset => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  IntColumn get sampleCount => integer().withDefault(const Constant(0))();
  BoolColumn get isCompleted => boolean().withDefault(const Constant(true))();
}

class SessionChunks extends Table {
  IntColumn get sessionId => integer()();
  IntColumn get chunkIndex => integer()();
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {sessionId, chunkIndex};
}

@DriftDatabase(tables: [Sessions, SessionChunks])
class AppDatabase extends _$AppDatabase {
  AppDatabase._([QueryExecutor? executor]) : super(executor ?? _openDefault());

  static AppDatabase? _instance;
  static AppDatabase get instance => _instance ??= AppDatabase._();

  /// For testing: create with a custom executor.
  factory AppDatabase.forTesting(QueryExecutor executor) =>
      AppDatabase._(executor);

  @override
  int get schemaVersion => 2;

  /// DEV ONLY: any schema version bump wipes the database and recreates it
  /// from scratch. No user data is migrated. Replace with real per-version
  /// migrations before release.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (Migrator m, int from, int to) async {
      for (final table in allTables) {
        await m.deleteTable(table.actualTableName);
      }
      await m.createAll();
    },
  );

  static QueryExecutor _openDefault() {
    return driftDatabase(
      name: 'dynamite_sessions',
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    );
  }

  // -- Session access --
  //
  // Every access pattern the app needs is a named method here; no drift query
  // expressions or Companions are constructed outside this file.

  /// Create a new recording session row, marked incomplete until
  /// [completeSession] finalizes it. Returns the generated id.
  Future<int> createSession({
    required String name,
    required int sampleRate,
    required int channelCount,
    required String channelLabels,
    required String tares,
    required double calibrationSlope,
    required int calibrationOffset,
    required String notes,
  }) {
    return into(sessions).insert(
      SessionsCompanion.insert(
        name: Value(name),
        createdAt: DateTime.now(),
        sampleRate: Value(sampleRate),
        channelCount: Value(channelCount),
        channelLabels: Value(channelLabels),
        tares: Value(tares),
        calibrationSlope: Value(calibrationSlope),
        calibrationOffset: Value(calibrationOffset),
        notes: Value(notes),
        isCompleted: const Value(false),
      ),
    );
  }

  /// Record a session's final aggregates and mark it completed.
  Future<void> completeSession(
    int id, {
    required int sampleCount,
    required int durationMs,
    required double peakForceRaw,
    required int peakForceChannel,
  }) {
    return _updateSession(
      id,
      SessionsCompanion(
        sampleCount: Value(sampleCount),
        durationMs: Value(durationMs),
        peakForceRaw: Value(peakForceRaw),
        peakForceChannel: Value(peakForceChannel),
        isCompleted: const Value(true),
      ),
    );
  }

  /// Rename a session.
  Future<void> renameSession(int id, String name) {
    return _updateSession(id, SessionsCompanion(name: Value(name)));
  }

  /// Replace a session's notes.
  Future<void> setSessionNotes(int id, String notes) {
    return _updateSession(id, SessionsCompanion(notes: Value(notes)));
  }

  /// Stream all completed sessions, newest first (reactive).
  Stream<List<Session>> watchAllSessions() {
    return (select(sessions)
          ..where((t) => t.isCompleted.equals(true))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  /// Get a single session by id.
  Future<Session?> sessionById(int id) {
    return (select(sessions)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Sessions that were never finalized (e.g. the app died mid-recording).
  Future<List<Session>> incompleteSessions() {
    return (select(sessions)..where((t) => t.isCompleted.equals(false))).get();
  }

  /// Delete a session and its chunks.
  Future<int> deleteSession(int id) {
    return transaction(() async {
      await (delete(sessionChunks)..where((t) => t.sessionId.equals(id))).go();
      return (delete(sessions)..where((t) => t.id.equals(id))).go();
    });
  }

  /// Append one chunk of packed sample bytes to a session.
  Future<void> insertChunk(int sessionId, int chunkIndex, Uint8List data) {
    return into(sessionChunks).insert(
      SessionChunksCompanion.insert(
        sessionId: sessionId,
        chunkIndex: chunkIndex,
        data: data,
      ),
    );
  }

  /// A session's chunk payloads, ordered by chunk index.
  Future<List<Uint8List>> sessionChunkData(int sessionId) async {
    final rows =
        await (select(sessionChunks)
              ..where((t) => t.sessionId.equals(sessionId))
              ..orderBy([(t) => OrderingTerm(expression: t.chunkIndex)]))
            .get();
    return [for (final r in rows) r.data];
  }

  Future<void> _updateSession(int id, SessionsCompanion entry) async {
    await (update(sessions)..where((t) => t.id.equals(id))).write(entry);
  }
}
