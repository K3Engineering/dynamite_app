import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/damaged_session.dart';
import '../models/session_summary.dart';
import 'live_session_writer.dart';
import 'session_data.dart';
import 'session_files.dart';
import 'session_id.dart';
import 'session_journal.dart';
import 'session_store_backend.dart';

/// The per-session file store. Each finalized recording is a directory under
/// the sessions root (see SessionFilesBackend for the layout and the
/// tail-only damage model); the journal holds all metadata, data.raw holds
/// all frames, and everything a listing or load needs is derived from the
/// two — there is no stored state that could disagree with the files.
class SessionStore {
  SessionStore._(Future<SessionFilesBackend> backend) : _backend = backend;

  static SessionStore? _instance;

  /// The app-wide store at the platform's default sessions root.
  static SessionStore get instance =>
      _instance ??= SessionStore._(createDefaultSessionFilesBackend());

  /// Swap the shared store (e.g. one pointing at a temp sessions root) so
  /// static storage APIs and the screens hit the test store.
  @visibleForTesting
  static set instance(SessionStore? store) => _instance = store;

  /// Wrap [backend] (a temp root in tests) instead of the platform default.
  factory SessionStore.over(SessionFilesBackend backend) =>
      SessionStore._(Future.value(backend));

  final Future<SessionFilesBackend> _backend;

  // -- Reactivity ------------------------------------------------------------

  /// Bumped by anything that can change a listing (sink creation,
  /// finalize, edits, deletes, recovery); watch streams re-read on bumps.
  final StreamController<void> _changes = StreamController.broadcast();

  /// Byte-size revisions: every append ack plus every [_changes] bump. The
  /// capacity strip's liveness rides the recording cadence through this.
  final StreamController<void> _bytes = StreamController.broadcast();

  void _bump() {
    if (!_changes.isClosed) _changes.add(null);
    _bumpBytes();
  }

  void _bumpBytes() {
    if (!_bytes.isClosed) _bytes.add(null);
  }

  /// The set-change pulse watch streams re-list/re-read on.
  Stream<void> get changes => _changes.stream;

  /// The byte-size pulse (append acks included) the capacity strip cues on.
  Stream<void> get byteChanges => _bytes.stream;

  /// Emit [read]'s result now and re-emit after every store mutation. A
  /// bump mid-read re-reads, so a lost race re-emits (self-healing) rather
  /// than showing a stale snapshot.
  Stream<T> watch<T>(Future<T> Function() read) async* {
    yield await read();
    await for (final _ in changes) {
      yield await read();
    }
  }

  // -- Recording side --------------------------------------------------------

  /// Open a new session directory for its first packet: mints the id,
  /// creates dir + journal + first data append in one backend round trip
  /// and hands back the sink. Called by the live writer at its FIRST data
  /// write only — a no-data recording leaves no artifact. Append acks bump
  /// [byteChanges] so the capacity strip tracks the recording live.
  Future<SessionDataSink> createDataSink({
    required SessionMeta meta,
    required Uint8List firstData,
  }) async {
    final files = await _backend;
    final id = newSessionId();
    final sink = await files.createSession(
      id,
      encodeSessionMeta(meta),
      firstData,
    );
    _bump();
    return NotifyingSessionDataSink._(sink, _bumpBytes);
  }

  /// Mark the session completed: the zero-byte [sessionFinalFile] marker,
  /// whose contentlessness is the point — counts derive from file lengths
  /// at read time, so a premature or out-of-date marker means nothing.
  Future<void> touchFinal(String id) async {
    await (await _backend).touchFinal(id);
    _bump();
  }

  /// Crash/aborted-record recovery: every directory that lacks `final`
  /// but proves to be a real session (journal parses, at least one frame)
  /// gets the marker touched. Creates at most one zero-byte file per dir
  /// and never deletes, truncates or repairs anything — a startup function
  /// can't tell a create-window tear from later corruption, so anything
  /// suspicious simply stays for the listing's damaged verdict.
  Future<void> recoverIncompleteSessions() async {
    final files = await _backend;
    for (final id in await files.listDirIds()) {
      if (await files.isFinalized(id)) continue;
      final journal = await _journalOrNull(files, id);
      if (journal == null) continue;
      final frames =
          await files.dataByteLength(id) ~/
          SessionChunkCodec(journal.meta.channelCount).frameBytes;
      if (frames < 1) continue;
      debugPrint('Recovering incomplete session: $id');
      await files.touchFinal(id);
      _bump();
    }
  }

  // -- Listing and load ------------------------------------------------------

  /// All finalized sessions, newest first (the id sorts chronologically,
  /// so descending ids IS descending creation order, ties included).
  Future<List<SessionSummary>> listSessions() async {
    final files = await _backend;
    final summaries = <SessionSummary>[];
    for (final id in await _sortedDirIds(files)) {
      final entry = await _classify(files, id);
      if (entry is _CompleteEntry) summaries.add(_summaryFor(entry));
    }
    return summaries;
  }

  /// One finalized session, or null when gone (deleted) or no longer
  /// loadable (the listing would flag it damaged instead).
  Future<SessionSummary?> sessionSummary(String id) async {
    final files = await _backend;
    final entry = await _classify(files, id);
    return entry is _CompleteEntry ? _summaryFor(entry) : null;
  }

  /// Directories the store can never load as sessions (unreadable header,
  /// malformed id, or header-without-data). Never persisted state — the
  /// verdict is re-derived from the bytes on every call.
  Future<List<DamagedSession>> listDamagedSessions() async {
    final files = await _backend;
    final damaged = <DamagedSession>[];
    for (final id in await _sortedDirIds(files)) {
      final entry = await _classify(files, id);
      if (entry is _DamagedEntry) damaged.add(entry.damaged);
    }
    return damaged;
  }

  /// Per-session data.raw byte lengths (the sessions list's size column).
  Future<Map<String, int>> sessionByteSizes() async {
    final files = await _backend;
    final sizes = <String, int>{};
    for (final id in await _sortedDirIds(files)) {
      final entry = await _classify(files, id);
      if (entry is _CompleteEntry) sizes[id] = entry.dataBytes;
    }
    return sizes;
  }

  Future<List<String>> _sortedDirIds(SessionFilesBackend files) async {
    final ids = await files.listDirIds();
    ids.sort((a, b) => b.compareTo(a));
    return ids;
  }

  Future<SessionJournal?> _journalOrNull(
    SessionFilesBackend files,
    String id,
  ) async {
    final bytes = await files.readJournal(id);
    if (bytes == null) return null;
    try {
      return parseSessionJournal(bytes);
    } on FormatException {
      return null;
    }
  }

  Future<_ListedEntry> _classify(SessionFilesBackend files, String id) async {
    final dataBytes = await files.dataByteLength(id);
    final journalBytes = await files.readJournal(id);
    final hasData = dataBytes > 0;
    final hasMeta = journalBytes != null && journalBytes.isNotEmpty;

    try {
      sessionIdCreatedAt(id);
    } on FormatException {
      return _DamagedEntry(
        DamagedSession(
          id: id,
          hasData: hasData,
          hasMeta: hasMeta,
          reason: 'Not a session this store wrote (malformed id)',
        ),
      );
    }

    SessionJournal journal;
    try {
      if (journalBytes == null) throw const FormatException('no journal');
      journal = parseSessionJournal(journalBytes);
    } on FormatException {
      return _DamagedEntry(
        DamagedSession(
          id: id,
          hasData: hasData,
          hasMeta: hasMeta,
          reason: 'Session metadata unreadable',
        ),
      );
    }

    final frames =
        dataBytes ~/ SessionChunkCodec(journal.meta.channelCount).frameBytes;
    if (frames < 1) {
      // Crash-at-create artifact: the header line landed, the first data
      // append never did.
      return _DamagedEntry(
        DamagedSession(
          id: id,
          hasData: hasData,
          hasMeta: hasMeta,
          reason: 'Recording never produced data',
        ),
      );
    }
    // A parseable, data-bearing dir without `final` is visible only to the
    // recording tab writing it (or to the prescan before recovery's touch) —
    // never to the listing.
    if (!await files.isFinalized(id)) return const _UnlistedEntry();
    return _CompleteEntry(id: id, journal: journal, dataBytes: dataBytes);
  }

  SessionSummary _summaryFor(_CompleteEntry entry) {
    final meta = entry.journal.meta;
    final edit = entry.journal.effectiveEdit;
    final frames =
        entry.dataBytes ~/ SessionChunkCodec(meta.channelCount).frameBytes;
    return SessionSummary(
      id: entry.id,
      name: edit.name,
      notes: edit.notes,
      createdAt: sessionIdCreatedAt(entry.id),
      durationMs: frames * 1000 ~/ meta.sampleRate,
      channelCount: meta.channelCount,
      sampleRate: meta.sampleRate,
      displayUnit: meta.displayUnit,
      deviceInfoJson: jsonEncode(meta.deviceInfo),
      recordedAt: meta.recordedAt,
      channelLabels: meta.channelLabels,
      visibleChannels: edit.visibleChannels,
    );
  }

  /// Read a session back: strict journal, frames = whole records in
  /// data.raw, sentinel runs becoming the [SessionData.gaps] hold-fills.
  /// A broken header or a frame shape the write path never produces
  /// throws (the detail view renders it as an error state).
  Future<SessionData> loadSession(String id) async {
    final files = await _backend;
    final journalBytes = await files.readJournal(id);
    if (journalBytes == null) {
      throw StateError('loadSession: no journal for session $id');
    }
    final journal = parseSessionJournal(journalBytes);
    final meta = journal.meta;
    final data = await files.readData(id);
    if (data == null) {
      throw StateError('loadSession: no data for session $id');
    }
    final decoded = SessionChunkCodec(meta.channelCount).decodeWithGaps(data);
    return SessionData(
      channels: decoded.channels,
      sampleRate: meta.sampleRate,
      sampleCount: decoded.channels.first.length,
      calibrations: meta.calibration,
      tares: meta.tares,
      gaps: decoded.gaps,
      ssnOrigin: meta.ssnOrigin,
      boardMeta: meta.boardMeta,
    );
  }

  /// data.raw's bytes verbatim, for the damaged entry's hand-recovery
  /// export. Throws StateError when absent — the affordance enabling it
  /// checked existence at list time, so a miss is a race, not a state.
  Future<Uint8List> rawDataBytes(String id) async {
    final bytes = await (await _backend).readData(id);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('no data bytes for session $id');
    }
    return bytes;
  }

  /// The journal's bytes verbatim, for the damaged entry's metadata export.
  Future<Uint8List> rawJournalBytes(String id) async {
    final bytes = await (await _backend).readJournal(id);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('no metadata bytes for session $id');
    }
    return bytes;
  }

  // -- Edits and destructive ops ---------------------------------------------

  /// Apply [update] to the session's effective display state and append
  /// the result as one whole-snapshot edit line (last complete line wins).
  /// Discipline: truncate to the last complete line first — usually a
  /// no-op, correct after a crash — so a new line never lands behind torn
  /// bytes.
  Future<void> editSession(
    String id,
    SessionEdit Function(SessionEdit current) update,
  ) async {
    final files = await _backend;
    final journalBytes = await files.readJournal(id);
    if (journalBytes == null) {
      throw StateError('editSession: no journal for session $id');
    }
    final journal = parseSessionJournal(journalBytes);
    final edit = update(journal.effectiveEdit);
    await files.truncateJournal(id, journal.completeBytes);
    await files.appendJournal(id, encodeSessionEdit(edit));
    _bump();
  }

  /// Delete the session directory wholesale. This is the ONLY destructive
  /// operation anywhere in the store, and it only ever runs on a user's
  /// explicit confirmation — recovery and listing never delete.
  Future<void> deleteSession(String id) async {
    await (await _backend).delete(id);
    _bump();
  }

  /// Total bytes of every session file — the native storage strip's "used"
  /// number (a directory walk never reports a high-water mark).
  Future<int> usedBytes() => _backend.then((f) => f.totalBytes());
}

sealed class _ListedEntry {
  const _ListedEntry();
}

final class _CompleteEntry extends _ListedEntry {
  const _CompleteEntry({
    required this.id,
    required this.journal,
    required this.dataBytes,
  });

  final String id;
  final SessionJournal journal;
  final int dataBytes;
}

final class _DamagedEntry extends _ListedEntry {
  const _DamagedEntry(this.damaged);
  final DamagedSession damaged;
}

/// Parseable and data-bearing but not finalized: the recording tab's
/// in-flight dir, invisible to every listing consumer.
final class _UnlistedEntry extends _ListedEntry {
  const _UnlistedEntry();
}

/// A [SessionDataSink] wrapper bumping the store's byte revisions on every
/// acked append so the capacity strip tracks the recording.
class NotifyingSessionDataSink implements SessionDataSink {
  const NotifyingSessionDataSink._(this.inner, this.onAppend);

  final SessionDataSink inner;
  final void Function() onAppend;

  @override
  String get id => inner.id;

  @override
  Future<int> append(Uint8List bytes) async {
    final length = await inner.append(bytes);
    onAppend();
    return length;
  }

  @override
  Future<void> close() => inner.close();
}
