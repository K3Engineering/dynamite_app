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

  /// Per-channel calibration in effect at recording time, as a JSON list of
  /// [ChannelCalibration] snapshots (board piecewise map + assigned load
  /// cell per channel). Playback converts through this, never through the
  /// live calibration, so later recalibration can't rewrite history.
  TextColumn get calibrationJson => text()();
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

  /// Device sample-counter value at the session's first sample (the
  /// dynamite-csv `ssn_origin` — docs/csv-format-v1.md). Non-nullable: a
  /// session row only ever exists alongside its first chunk (see
  /// [AppDatabase.createSessionWithFirstChunk]), and the writer knows the
  /// origin by the time that row is created.
  IntColumn get ssnOrigin => integer()();

  /// The app's display unit at recording start (a `DisplayUnit.name`),
  /// frozen as the CSV export's default converted unit — the
  /// recording-time snapshot requirement of docs/csv-format-v1.md.
  TextColumn get displayUnit => text()();

  /// The connected device's identity at recording start (BLE name + the DIS
  /// strings), as the JSON-encoded dynamite-csv `device` metadata block —
  /// see `toCsvDeviceMetadata` in csv_export.dart. Frozen so export never
  /// consults live device state (docs/csv-format-v1.md).
  TextColumn get deviceInfoJson => text()();
}

/// The [Sessions]-row metadata snapshotted at recording start, frozen for
/// playback and export. The live writer ([LiveSessionWriter]) carries it
/// until its first chunk flush creates the row — see
/// [AppDatabase.createSessionWithFirstChunk].
typedef SessionHeader = ({
  String name,
  int sampleRate,
  int channelCount,
  String channelLabels,
  String tares,
  String calibrationJson,
  String visibleChannels,
  String displayUnit,
  String deviceInfoJson,
});

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

  factory AppDatabase.forTesting(QueryExecutor executor) =>
      AppDatabase._(executor);

  /// Session-row creation must not race crash recovery's incomplete-session
  /// scan: recovery runs after the first frame (see main()), so its SELECT
  /// executes once the DB opens — on a cold web load, seconds after a
  /// recording could already have created its isCompleted=false row, which
  /// recovery must not finalize. The live writer awaits this before
  /// creating its row. The completed default keeps tests and non-main
  /// entry points ungated.
  static Future<void> crashRecoveryFence = Future.value();

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
  int get schemaVersion => 13;

  /// DEV ONLY: any schema version bump wipes the database and recreates it
  /// from scratch. No user data is migrated. Replace with real per-version
  /// migrations before release.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      // auto_vacuum must be set before any table exists; afterwards SQLite
      // ignores the pragma until the next VACUUM. With FULL, every commit
      // that frees pages (session deletes, the dev wipe below) also shrinks
      // the file — without it the file sits at its high-water mark forever.
      await m.database.customStatement('PRAGMA auto_vacuum = FULL');
      await m.createAll();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      await m.database.customStatement('PRAGMA auto_vacuum = FULL');
      for (final table in allTables) {
        await m.deleteTable(table.actualTableName);
      }
      await m.createAll();
      // Converts a pre-auto_vacuum file and reclaims the space the wipe
      // just freed (DELETE alone never shrinks the file).
      await m.database.customStatement('VACUUM');
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

  /// Insert a bare session row (no chunks), marked incomplete until
  /// [completeSession] finalizes it. Returns the generated id.
  ///
  /// Production rows come from [createSessionWithFirstChunk] instead: a
  /// session row exists only alongside its first chunk, so [ssnOrigin] can
  /// never be unknown and crash recovery never sees a dataless session.
  /// Tests that need chunk-less rows (ordering, empty UI states) use this;
  /// production code must not. [createdAt] defaults to now; tests inject it
  /// to control ordering ties.
  @visibleForTesting
  Future<int> createSession({
    required String name,
    required int sampleRate,
    required int channelCount,
    required String channelLabels,
    required String tares,
    required String calibrationJson,
    required String visibleChannels,
    required String displayUnit,
    required String deviceInfoJson,
    required int ssnOrigin,
    String gaps = '[]',
    DateTime? createdAt,
  }) {
    return into(sessions).insert(
      SessionsCompanion.insert(
        name: Value(name),
        createdAt: createdAt ?? DateTime.now(),
        sampleRate: sampleRate,
        channelCount: channelCount,
        channelLabels: channelLabels,
        tares: tares,
        calibrationJson: calibrationJson,
        isCompleted: const Value(false),
        gaps: Value(gaps),
        visibleChannels: visibleChannels,
        displayUnit: displayUnit,
        deviceInfoJson: deviceInfoJson,
        ssnOrigin: ssnOrigin,
      ),
    );
  }

  /// Create a new recording session row together with its first chunk,
  /// atomically: the row and the chunk land in one transaction, so in
  /// production a [Sessions] row can never exist without data. Called by
  /// the live writer's first chunk flush, at which point the device-counter
  /// origin ([ssnOrigin]) and the gap ranges accrued so far ([gaps]) are
  /// known — both are recorded with the row itself.
  Future<int> createSessionWithFirstChunk({
    required SessionHeader header,
    required int ssnOrigin,
    required String gaps,
    required Uint8List data,
  }) {
    return transaction(() async {
      final id = await createSession(
        name: header.name,
        sampleRate: header.sampleRate,
        channelCount: header.channelCount,
        channelLabels: header.channelLabels,
        tares: header.tares,
        calibrationJson: header.calibrationJson,
        visibleChannels: header.visibleChannels,
        displayUnit: header.displayUnit,
        deviceInfoJson: header.deviceInfoJson,
        ssnOrigin: ssnOrigin,
        gaps: gaps,
      );
      await into(sessionChunks).insert(
        SessionChunksCompanion.insert(sessionId: id, chunkIndex: 0, data: data),
      );
      return id;
    });
  }

  /// Record a session's final aggregate (sample count) and mark it
  /// completed. [gaps] is the JSON-encoded dropped-sample range list
  /// (session-relative); crash recovery passes the row's existing value so
  /// the ranges the live writer persisted incrementally (see
  /// [appendChunkAndGaps]) survive the crash.
  Future<void> completeSession(
    int id, {
    required int sampleCount,
    required int durationMs,
    String gaps = '[]',
  }) {
    return _updateSession(
      id,
      SessionsCompanion(
        sampleCount: Value(sampleCount),
        durationMs: Value(durationMs),
        isCompleted: const Value(true),
        gaps: Value(gaps),
      ),
    );
  }

  Future<void> renameSession(int id, String name) {
    return _updateSession(id, SessionsCompanion(name: Value(name)));
  }

  Future<void> setSessionNotes(int id, String notes) {
    return _updateSession(id, SessionsCompanion(notes: Value(notes)));
  }

  /// Replace a session's visible-channel set ([json] is a JSON bool list).
  Future<void> setSessionVisibleChannels(int id, String json) {
    return _updateSession(id, SessionsCompanion(visibleChannels: Value(json)));
  }

  /// Stream all completed sessions, newest first (reactive). createdAt is
  /// stored at one-second resolution, so sessions created within the same
  /// second tie — break ties by id (monotonic with insertion) to keep the
  /// order total and rows from swapping between stream emissions.
  Stream<List<Session>> watchAllSessions() {
    return (select(sessions)
          ..where((t) => t.isCompleted.equals(true))
          ..orderBy([
            (t) => OrderingTerm.desc(t.createdAt),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .watch();
  }

  Future<Session?> sessionById(int id) {
    return (select(sessions)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Watch a single session row (reactive).
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

  /// Append one chunk of packed sample bytes to a session, keeping the row's
  /// gap ranges current in the same unit of work.
  ///
  /// One transaction because the two must land or fail together: the row's
  /// gap ranges describe every chunk up to the latest, so a chunk persisted
  /// without its updated ranges (or ranges ahead of their chunk) would
  /// misread held values as data on load.
  Future<void> appendChunkAndGaps(
    int sessionId,
    int chunkIndex,
    Uint8List data,
    String gapsJson,
  ) {
    return transaction(() async {
      await into(sessionChunks).insert(
        SessionChunksCompanion.insert(
          sessionId: sessionId,
          chunkIndex: chunkIndex,
          data: data,
        ),
      );
      await _updateSession(sessionId, SessionsCompanion(gaps: Value(gapsJson)));
    });
  }

  /// Append one chunk of packed sample bytes to a session.
  Future<void> insertChunk(
    int sessionId,
    int chunkIndex,
    Uint8List data,
  ) async {
    await into(sessionChunks).insert(
      SessionChunksCompanion.insert(
        sessionId: sessionId,
        chunkIndex: chunkIndex,
        data: data,
      ),
    );
  }

  /// A session's chunk rows (index + payload), ordered by chunk index.
  /// Integrity verification needs the indices (see [verifyChunkIntegrity]),
  /// so payloads never travel without them.
  Future<List<SessionChunk>> sessionChunkRows(int sessionId) {
    return (select(sessionChunks)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([(t) => OrderingTerm(expression: t.chunkIndex)]))
        .get();
  }

  /// Per-session chunk payload sizes in bytes (exact blob lengths),
  /// reactive: re-emits on every chunk insert/delete, so the Sessions tab's
  /// card sizes and capacity strip stay fresh while a recording writes.
  Stream<Map<int, int>> watchSessionByteSizes() {
    return customSelect(
      'SELECT session_id, SUM(LENGTH(data)) AS bytes '
      'FROM session_chunks GROUP BY session_id',
      readsFrom: {sessionChunks},
    ).watch().map(
      (rows) => {
        for (final r in rows) r.read<int>('session_id'): r.read<int>('bytes'),
      },
    );
  }

  /// Exact on-disk database size (page_count x page_size) — the native
  /// storage strip's "used" number.
  Future<int> databaseFileBytes() async {
    final count = await customSelect('PRAGMA page_count').getSingle();
    final size = await customSelect('PRAGMA page_size').getSingle();
    return count.read<int>('page_count') * size.read<int>('page_size');
  }

  Future<void> _updateSession(int id, SessionsCompanion entry) async {
    await (update(sessions)..where((t) => t.id.equals(id))).write(entry);
  }
}
