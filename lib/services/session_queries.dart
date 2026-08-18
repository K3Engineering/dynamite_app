/// The screens' only database read/modify path for session rows: streams of
/// [SessionSummary] plus the row-level actions (rename, notes, visibility,
/// delete). The drift row type never leaves this file (and database.dart) —
/// UI code works with [SessionSummary].
library;

import '../models/session_summary.dart';
import 'database.dart';
import 'session_storage.dart';

/// All sessions, newest-first (same ordering as the DB stream), mapped to
/// the UI model.
Stream<List<SessionSummary>> watchSessionSummaries() => AppDatabase.instance
    .watchAllSessions()
    .map((rows) => [for (final row in rows) sessionSummaryFor(row)]);

/// Per-session chunk byte sizes (the sessions list's size column and the
/// capacity strip's refresh cue).
Stream<Map<int, int>> watchSessionByteSizes() =>
    AppDatabase.instance.watchSessionByteSizes();

/// One session, reactively — name, notes, and per-session channel
/// visibility surface here as edits land.
Stream<SessionSummary?> watchSessionSummary(int id) => AppDatabase.instance
    .watchSessionById(id)
    .map((row) => row == null ? null : sessionSummaryFor(row));

/// Fetch a session by id (null when gone).
Future<SessionSummary?> sessionSummaryById(int id) async {
  final row = await AppDatabase.instance.sessionById(id);
  return row == null ? null : sessionSummaryFor(row);
}

/// The DB file's exact byte size — the capacity strip's used portion.
Future<int> sessionDatabaseFileBytes() =>
    AppDatabase.instance.databaseFileBytes();

/// Map a drift row to the UI model. The JSON-column parse fallbacks match
/// the columns' display-only contract (see [parseJsonColumn]).
SessionSummary sessionSummaryFor(Session row) => SessionSummary(
  id: row.id,
  name: row.name,
  notes: row.notes,
  createdAt: row.createdAt,
  durationMs: row.durationMs,
  channelCount: row.channelCount,
  sampleRate: row.sampleRate,
  displayUnit: row.displayUnit,
  deviceInfoJson: row.deviceInfoJson,
  channelLabels: parseJsonColumn(
    row.channelLabels,
    row.channelCount,
    convert: (e) => e.toString(),
    fallback: (i) => 'Ch ${i + 1}',
  ),
  visibleChannels: parseJsonColumn(
    row.visibleChannels,
    row.channelCount,
    convert: (e) => e == true,
    fallback: (_) => true,
  ),
);

Future<void> renameSession(int id, String name) =>
    AppDatabase.instance.renameSession(id, name);

Future<void> setSessionNotes(int id, String notes) =>
    AppDatabase.instance.setSessionNotes(id, notes);

Future<void> setSessionVisibleChannels(int id, List<bool> visible) =>
    AppDatabase.instance.setSessionVisibleChannels(
      id,
      encodeVisibleChannels(visible),
    );

Future<void> deleteSession(int id) async {
  await AppDatabase.instance.deleteSession(id);
}
