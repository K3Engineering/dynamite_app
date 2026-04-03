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
  RealColumn get peakForceRaw => real().withDefault(const Constant(0.0))();
  IntColumn get peakForceChannel => integer().withDefault(const Constant(0))();
  RealColumn get calibrationSlope =>
      real().withDefault(const Constant(0.0001117587))();
  IntColumn get calibrationOffset => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  IntColumn get sampleCount => integer().withDefault(const Constant(0))();
}

class SessionBlobs extends Table {
  IntColumn get sessionId => integer()();
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {sessionId};
}

@DriftDatabase(tables: [Sessions, SessionBlobs])
class AppDatabase extends _$AppDatabase {
  AppDatabase._([QueryExecutor? executor]) : super(executor ?? _openDefault());

  static AppDatabase? _instance;
  static AppDatabase get instance => _instance ??= AppDatabase._();

  /// For testing: create with a custom executor.
  factory AppDatabase.forTesting(QueryExecutor executor) =>
      AppDatabase._(executor);

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openDefault() {
    return driftDatabase(
      name: 'dynamite_sessions',
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    );
  }

  // -- CRUD operations --

  /// Insert a new session, returns the generated id.
  Future<int> insertSession(SessionsCompanion entry) {
    return into(sessions).insert(entry);
  }

  /// Get all sessions ordered by creation date descending.
  Future<List<Session>> allSessions() {
    return (select(
      sessions,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();
  }

  /// Stream all sessions (reactive).
  Stream<List<Session>> watchAllSessions() {
    return (select(
      sessions,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();
  }

  /// Get a single session by id.
  Future<Session?> sessionById(int id) {
    return (select(sessions)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Update a session.
  Future<bool> updateSession(int id, SessionsCompanion entry) {
    return (update(
      sessions,
    )..where((t) => t.id.equals(id))).write(entry).then((rows) => rows > 0);
  }

  /// Delete a session.
  Future<int> deleteSession(int id) {
    return transaction(() async {
      await (delete(sessionBlobs)..where((t) => t.sessionId.equals(id))).go();
      return (delete(sessions)..where((t) => t.id.equals(id))).go();
    });
  }
}
