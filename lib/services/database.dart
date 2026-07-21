import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';

part 'database.g.dart';

/// Table for recorded measurement sessions.
///
/// Columns whose value must be chosen deliberately at insert time (sample
/// rate, channel layout, tares, calibration, visibility) carry NO default, so
/// drift makes them compile-time required on insert — a stale fallback can
/// never silently land in a row. Harmless display/aggregate defaults (`name`,
/// `notes`, counters, flags) are kept.
class Sessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  IntColumn get sampleRate => integer()();
  IntColumn get channelCount => integer()();
  TextColumn get channelLabels => text()();
  TextColumn get tares => text()();
  RealColumn get peakForceRaw => real().withDefault(const Constant(0.0))();
  RealColumn get calibrationSlope => real()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  IntColumn get sampleCount => integer().withDefault(const Constant(0))();
  BoolColumn get isCompleted => boolean().withDefault(const Constant(true))();

  /// Dropped-sample ranges as JSON `[[start,end],...]`, session-relative,
  /// half-open. The chunk data holds held values across these ranges.
  TextColumn get gaps => text().withDefault(const Constant('[]'))();

  /// Which channels are shown in the session detail view, as a JSON bool
  /// list. Initialized from the live view's channel selection at recording
  /// time; afterwards it is per-session and independent of the live view.
  TextColumn get visibleChannels => text()();
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

  /// For testing: swap the shared instance (e.g. an in-memory DB built with
  /// [AppDatabase.forTesting]) so static storage APIs like `SessionStorage`
  /// hit the test database. Pair with [closeInstance] in tearDown so the next
  /// [instance] access re-opens the default connection.
  @visibleForTesting
  static set instance(AppDatabase? db) => _instance = db;

  /// For testing: create with a custom executor.
  factory AppDatabase.forTesting(QueryExecutor executor) =>
      AppDatabase._(executor);

  /// Close the shared instance (if open) and reset the singleton, so the
  /// next [instance] access opens a fresh connection — which is when drift
  /// runs schema migrations. The web hot-restart cleanup uses this: hot
  /// reload/restart keeps the old generation's open connection (and its old
  /// schema) alive otherwise, so a bumped [schemaVersion] would never take
  /// effect until a cold start.
  static Future<void> closeInstance() async {
    final db = _instance;
    _instance = null;
    await db?.close();
  }

  @override
  int get schemaVersion => 7;

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
    required String visibleChannels,
  }) {
    return into(sessions).insert(
      SessionsCompanion.insert(
        name: Value(name),
        createdAt: DateTime.now(),
        sampleRate: sampleRate,
        channelCount: channelCount,
        channelLabels: channelLabels,
        tares: tares,
        calibrationSlope: calibrationSlope,
        isCompleted: const Value(false),
        visibleChannels: visibleChannels,
      ),
    );
  }

  /// Record a session's final aggregates and mark it completed. [gaps] is the
  /// JSON-encoded dropped-sample range list (session-relative); crash recovery
  /// passes the row's existing value so the ranges the live writer persisted
  /// incrementally (see [setSessionGaps]) survive the crash.
  Future<void> completeSession(
    int id, {
    required int sampleCount,
    required int durationMs,
    required double peakForceRaw,
    String gaps = '[]',
  }) {
    return _updateSession(
      id,
      SessionsCompanion(
        sampleCount: Value(sampleCount),
        durationMs: Value(durationMs),
        peakForceRaw: Value(peakForceRaw),
        isCompleted: const Value(true),
        gaps: Value(gaps),
      ),
    );
  }

  /// Replace a session's dropped-sample ranges ([gaps] is the JSON-encoded
  /// range list, session-relative). Called by the live writer on every chunk
  /// flush, so a crash mid-recording keeps the gap info up to the last
  /// flushed chunk instead of losing it all (crash recovery only rebuilds
  /// aggregates; it cannot reconstruct gaps from chunk bytes).
  Future<void> setSessionGaps(int id, String gaps) {
    return _updateSession(id, SessionsCompanion(gaps: Value(gaps)));
  }

  /// Rename a session.
  Future<void> renameSession(int id, String name) {
    return _updateSession(id, SessionsCompanion(name: Value(name)));
  }

  /// Replace a session's notes.
  Future<void> setSessionNotes(int id, String notes) {
    return _updateSession(id, SessionsCompanion(notes: Value(notes)));
  }

  /// Replace a session's visible-channel set ([json] is a JSON bool list).
  Future<void> setSessionVisibleChannels(int id, String json) {
    return _updateSession(id, SessionsCompanion(visibleChannels: Value(json)));
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

  /// Watch a single session row (reactive). The detail screen's source of
  /// truth: edits made from anywhere (rename, notes, channel visibility)
  /// surface without manual reloads.
  Stream<Session?> watchSessionById(int id) {
    return (select(
      sessions,
    )..where((t) => t.id.equals(id))).watchSingleOrNull();
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
