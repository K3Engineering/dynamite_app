import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/damaged_session.dart';
import '../models/session_catalog.dart';
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

  // -- Catalog and operation ordering ----------------------------------------

  final ValueNotifier<SessionCatalogState> _catalog = ValueNotifier(
    const SessionCatalogLoading(),
  );
  Future<void> _operationTail = Future.value();
  Future<void>? _initialCatalogLoad;

  ValueListenable<SessionCatalogState> get catalog => _catalog;

  /// Byte-size revisions: every append ack plus every catalog publication.
  /// The capacity strip's liveness rides the recording cadence through this.
  final StreamController<void> _bytes = StreamController.broadcast();

  void _bumpBytes() {
    if (!_bytes.isClosed) _bytes.add(null);
  }

  /// The byte ledger behind [usedBytes]: seeded by every catalog publish
  /// (the scan already stats every directory, so it costs no extra I/O and
  /// re-reads ground truth), and kept current between publishes by exact
  /// deltas from the ops below. A directory walk per capacity-strip pulse
  /// would scale with the session count forever; this ledger does one
  /// walk-equivalent per publish and none per pulse.
  int? _byteTotal;

  /// Fold [delta] into the ledger. Deltas only apply once a publish has
  /// seeded the ledger — a write that landed BEFORE the first seed is
  /// already inside the seed's stat, so skipping the delta is correct,
  /// not lossy.
  void _addBytes(int delta) {
    final total = _byteTotal;
    if (total != null) _byteTotal = total + delta;
  }

  /// The byte-size pulse (append acks included) the capacity strip cues on.
  Stream<void> get byteChanges => _bytes.stream;

  Future<T> _enqueue<T>(
    Future<T> Function(SessionFilesBackend files) operation,
  ) {
    final result = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        result.complete(await operation(await _backend));
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  StateError get _catalogUnavailable => switch (_catalog.value) {
    SessionCatalogFailed(:final error) => StateError(
      'Session catalog is unavailable: $error',
    ),
    _ => throw StateError('catalog is available'),
  };

  void _requireCatalogAvailable() {
    if (_catalog.value is SessionCatalogFailed) throw _catalogUnavailable;
  }

  Future<void> ensureCatalogLoaded() {
    // A failed future, not a sync throw: callers swallow it in a catchError
    // and let the Failed state render through the listenable, identically
    // to a publish failure landing after the call.
    if (_catalog.value is SessionCatalogFailed) {
      return Future.error(_catalogUnavailable);
    }
    if (_catalog.value is SessionCatalogReady) return Future.value();
    return _initialCatalogLoad ??= _enqueue(_publishCatalog);
  }

  /// Re-read every session directory and republish the catalog. The cache
  /// is derived state, so a full re-read always supersedes the deltas —
  /// this is also a Failed catalog's only way back.
  Future<void> refreshCatalog() => _enqueue(_publishCatalog);

  Future<void> _loadCatalogIfNeeded(SessionFilesBackend files) async {
    if (_catalog.value is SessionCatalogLoading) await _publishCatalog(files);
    _requireCatalogAvailable();
  }

  /// Run [operation] on the serialized queue with the catalog guaranteed
  /// loaded and available. Mutations apply their own delta to the published
  /// catalog (see [_refreshCatalogEntry]); reads need nothing more.
  Future<T> _withCatalog<T>(
    Future<T> Function(SessionFilesBackend files) operation,
  ) => _enqueue((files) async {
    await _loadCatalogIfNeeded(files);
    return operation(files);
  });

  /// Re-publish the in-memory catalog after a mutation whose effect is
  /// known exactly. Callers run inside the operation queue, so the Ready
  /// catalog can only have drifted from disk through our own deltas — no
  /// re-scan needed.
  void _publishDelta(SessionCatalog Function(SessionCatalog current) update) {
    if (_catalog.value case SessionCatalogReady(:final catalog)) {
      _catalog.value = SessionCatalogReady(update(catalog));
      _bumpBytes();
      return;
    }
    throw StateError('catalog delta requires a ready catalog');
  }

  /// Splice [id]'s freshly classified entry into the published catalog. The
  /// classification is the only I/O (one session, not a full re-scan); if
  /// it fails the fallback is a full publish — the catalog is derived
  /// state, so a full re-read always re-establishes truth, no stale delta
  /// can survive it. Only a failed re-read is terminal (same as every
  /// other publish failure).
  Future<void> _refreshCatalogEntry(
    SessionFilesBackend files,
    String id,
  ) async {
    _ListedEntry entry;
    try {
      entry = await _classify(files, id);
    } catch (_) {
      await _publishCatalog(files);
      return;
    }
    _publishDelta((catalog) => _spliceEntry(catalog, id, entry));
  }

  /// [catalog] with [id]'s entry replaced by [entry]'s verdict (or
  /// removed); SessionCatalog's constructor owns the ordering.
  SessionCatalog _spliceEntry(
    SessionCatalog catalog,
    String id,
    _ListedEntry entry,
  ) {
    final sessions = [...catalog.sessions]..removeWhere((s) => s.id == id);
    final damaged = [...catalog.damaged]..removeWhere((d) => d.id == id);
    final byteSizes = {...catalog.byteSizes}..remove(id);
    switch (entry) {
      case final _CompleteEntry complete:
        sessions.add(_summaryFor(complete));
        byteSizes[id] = complete.dataBytes;
      case final _DamagedEntry damagedEntry:
        damaged.add(damagedEntry.damaged);
      case _UnlistedEntry():
    }
    return SessionCatalog(
      sessions: sessions,
      damaged: damaged,
      byteSizes: byteSizes,
    );
  }

  Future<void> _publishCatalog(SessionFilesBackend files) async {
    try {
      final read = await _readCatalogDefended(files);
      _catalog.value = SessionCatalogReady(read.catalog);
      // Every publish re-seeds the byte ledger from the scan: the deltas
      // that accumulate between publishes are superseded by ground truth.
      _byteTotal = read.byteTotal;
      _bumpBytes();
    } catch (error, stackTrace) {
      _catalog.value = SessionCatalogFailed(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// The catalog read, retried once inline: a one-shot backend failure
  /// (a transient file lock on the native side is the realistic case)
  /// must not brick the store, but a read that fails twice is a real
  /// problem — report it and stop.
  Future<({SessionCatalog catalog, int byteTotal})> _readCatalogDefended(
    SessionFilesBackend files,
  ) async {
    try {
      return await _readCatalog(files);
    } catch (_) {
      return _readCatalog(files);
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
  }) => _enqueue((files) async {
    _requireCatalogAvailable();
    final metaBytes = encodeSessionMeta(meta);
    final SessionDataSink sink;
    try {
      sink = await files.createSession(newSessionId(), metaBytes, firstData);
    } catch (_) {
      // Both backends can tear here with dir + journal already on disk —
      // publish so the artifact lists as damaged now instead of first
      // appearing at next startup's recovery. Best-effort: a publish that
      // also fails records the Failed catalog itself; the create error
      // below stays the one thrown to the caller.
      try {
        await _publishCatalog(files);
      } catch (_) {}
      rethrow;
    }
    // The fresh dir has no `final` marker, so the listing is unchanged by
    // construction and no catalog load is forced; the finalization's delta
    // loads it if needed. Only the byte totals grew.
    _addBytes(metaBytes.length + firstData.length);
    _bumpBytes();
    return NotifyingSessionDataSink._(sink, firstData.length, (delta) {
      _addBytes(delta);
      _bumpBytes();
    });
  });

  /// Mark the session completed: the zero-byte [sessionFinalFile] marker,
  /// whose contentlessness is the point — counts derive from file lengths
  /// at read time, so a premature or out-of-date marker means nothing.
  Future<void> touchFinal(String id) => _withCatalog((files) async {
    await files.touchFinal(id);
    await _refreshCatalogEntry(files, id);
  });

  /// Crash/aborted-record recovery: every directory that lacks `final`
  /// but proves to be a real session (journal parses, at least one frame)
  /// gets the marker touched. Creates at most one zero-byte file per dir
  /// and never deletes, truncates or repairs anything — a startup function
  /// can't tell a create-window tear from later corruption, so anything
  /// suspicious simply stays for the listing's damaged verdict.
  Future<void> recoverIncompleteSessions() => _enqueue((files) async {
    _requireCatalogAvailable();
    try {
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
      }
      await _publishCatalog(files);
    } catch (_) {
      // Recovery is idempotent (marker touches only), so a failure mid-loop
      // needs no rollback or retry of the loop itself: republish — the
      // recovered-so-far set is on disk already, and whatever the loop
      // missed is picked up by next startup's recovery. Only a publish
      // that also fails poisons the catalog, from inside _publishCatalog.
      await _publishCatalog(files);
    }
  });

  // -- Listing and load ------------------------------------------------------

  /// The full directory read: the catalog plus the sessions total byte
  /// count the scan computes for free along the way (every classify
  /// already stats data.raw and reads the journal; sum them instead of
  /// walking the tree again for the capacity strip).
  Future<({SessionCatalog catalog, int byteTotal})> _readCatalog(
    SessionFilesBackend files,
  ) async {
    final summaries = <SessionSummary>[];
    final damaged = <DamagedSession>[];
    final sizes = <String, int>{};
    var byteTotal = 0;
    for (final id in await files.listDirIds()) {
      final entry = await _classify(files, id);
      byteTotal += entry.byteTotal;
      switch (entry) {
        case final _CompleteEntry complete:
          summaries.add(_summaryFor(complete));
          sizes[id] = complete.dataBytes;
        case final _DamagedEntry entry:
          damaged.add(entry.damaged);
        case _UnlistedEntry():
      }
    }
    return (
      catalog: SessionCatalog(
        sessions: summaries,
        damaged: damaged,
        byteSizes: sizes,
      ),
      byteTotal: byteTotal,
    );
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
    // The `final` marker is zero bytes by design, so data + journal IS the
    // directory's byte total.
    final byteTotal = dataBytes + (journalBytes?.length ?? 0);

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
        byteTotal: byteTotal,
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
        byteTotal: byteTotal,
      );
    }

    final frameBytes = SessionChunkCodec(journal.meta.channelCount).frameBytes;
    if (dataBytes % frameBytes != 0) {
      // A write torn mid-frame: no prefix of this file is the recording,
      // so the session is damaged rather than silently shortened.
      return _DamagedEntry(
        DamagedSession(
          id: id,
          hasData: hasData,
          hasMeta: hasMeta,
          reason: 'Sample data ends mid-frame',
        ),
        byteTotal: byteTotal,
      );
    }
    final frames = dataBytes ~/ frameBytes;
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
        byteTotal: byteTotal,
      );
    }
    // A parseable, data-bearing dir without `final` is visible only to the
    // recording tab writing it (or to the prescan before recovery's touch) —
    // never to the listing.
    if (!await files.isFinalized(id)) {
      return _UnlistedEntry(byteTotal: byteTotal);
    }
    return _CompleteEntry(
      id: id,
      journal: journal,
      dataBytes: dataBytes,
      byteTotal: byteTotal,
    );
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

  /// Read a session back: strict journal, whole frames from data.raw,
  /// sentinel runs becoming the [SessionData.gaps] hold-fills. A broken
  /// header, a byte count that doesn't divide into frames, or a frame
  /// shape the write path never produces throws (the detail view renders
  /// it as an error state).
  Future<SessionData> loadSession(String id) => _withCatalog((files) async {
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
  });

  /// data.raw's bytes verbatim, for the damaged entry's hand-recovery
  /// export. Throws StateError when absent — the affordance enabling it
  /// checked existence at list time, so a miss is a race, not a state.
  /// Raw reads are rescue hatches: they depend on one file being
  /// readable, not on the catalog's health, and only ride the queue for
  /// ordering against mutations of this id.
  Future<Uint8List> rawDataBytes(String id) => _enqueue((files) async {
    final bytes = await files.readData(id);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('no data bytes for session $id');
    }
    return bytes;
  });

  /// The journal's bytes verbatim, for the damaged entry's metadata export.
  Future<Uint8List> rawJournalBytes(String id) => _enqueue((files) async {
    final bytes = await files.readJournal(id);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('no metadata bytes for session $id');
    }
    return bytes;
  });

  // -- Edits and destructive ops ---------------------------------------------

  /// Apply [update] to the session's effective display state and append
  /// the result as one whole-snapshot edit line (last complete line wins).
  /// Discipline: truncate to the last complete line first — usually a
  /// no-op, correct after a crash — so a new line never lands behind torn
  /// bytes.
  Future<void> editSession(
    String id,
    SessionEdit Function(SessionEdit current) update,
  ) => _withCatalog((files) async {
    final journalBytes = await files.readJournal(id);
    if (journalBytes == null) {
      throw StateError('editSession: no journal for session $id');
    }
    final journal = parseSessionJournal(journalBytes);
    final edit = update(journal.effectiveEdit);
    final append = encodeSessionEdit(edit);
    await files.truncateJournal(id, journal.completeBytes);
    await files.appendJournal(id, append);
    _addBytes(journal.completeBytes + append.length - journalBytes.length);
    await _refreshCatalogEntry(files, id);
  });

  Future<void> toggleVisibleChannel(String id, int index) =>
      editSession(id, (current) {
        final visible = [...current.visibleChannels];
        visible[index] = !visible[index];
        return SessionEdit(
          name: current.name,
          notes: current.notes,
          visibleChannels: visible,
        );
      });

  /// Delete the session directory. This is the ONLY destructive operation
  /// anywhere in the store, and it only ever runs on a user's explicit
  /// confirmation — recovery and listing never delete. Only the layout's
  /// three named files are destroyed (see SessionFilesBackend.delete).
  Future<void> deleteSession(String id) => _withCatalog((files) async {
    // Measure before deleting so the ledger subtracts what actually left
    // the disk, not a catalog value that could have drifted.
    final dataBytes = await files.dataByteLength(id);
    final journalBytes = (await files.readJournal(id))?.length ?? 0;
    await files.delete(id);
    _addBytes(-(dataBytes + journalBytes));
    _publishDelta(
      (catalog) =>
          _spliceEntry(catalog, id, const _UnlistedEntry(byteTotal: 0)),
    );
  });

  /// Total bytes of every session file — the native storage strip's "used"
  /// number. The byte ledger (see [_byteTotal]): seeded by the scan side
  /// of every publish and adjusted by exact deltas between them, so this
  /// is only trivially stale (a publish mid-recording stats at some point
  /// in the append stream and the ack deltas close the gap). Stray files
  /// the layout can't name don't count — the scan only sees session dirs.
  Future<int> usedBytes() => _withCatalog((files) async {
    final total = _byteTotal;
    if (total == null) {
      // _withCatalog guarantees a publish ran (catalog Ready seeds the
      // ledger on the way through), so this is unreachable — fail loudly
      // rather than paper over the invariant with null-coalescing.
      throw StateError('usedBytes: catalog ready without a byte seed');
    }
    return total;
  });
}

sealed class _ListedEntry {
  const _ListedEntry({required this.byteTotal});

  /// The directory's bytes as the classification scan found them (data +
  /// journal; the `final` marker is zero bytes by design).
  final int byteTotal;
}

final class _CompleteEntry extends _ListedEntry {
  const _CompleteEntry({
    required this.id,
    required this.journal,
    required this.dataBytes,
    required super.byteTotal,
  });

  final String id;
  final SessionJournal journal;
  final int dataBytes;
}

final class _DamagedEntry extends _ListedEntry {
  const _DamagedEntry(this.damaged, {required super.byteTotal});
  final DamagedSession damaged;
}

/// Parseable and data-bearing but not finalized: the recording tab's
/// in-flight dir, invisible to every listing consumer (its bytes still
/// count in the scan total).
final class _UnlistedEntry extends _ListedEntry {
  const _UnlistedEntry({required super.byteTotal});
}

/// A [SessionDataSink] wrapper folding every acked append's growth into
/// the store's byte ledger and bumping the byte revisions so the capacity
/// strip tracks the recording. Deltas are ack-relative, so a publish's
/// ledger re-seed (which re-stats data.raw) never double-counts them.
class NotifyingSessionDataSink implements SessionDataSink {
  NotifyingSessionDataSink._(this.inner, int ackedBytes, this.onAppend)
    : _ackedBytes = ackedBytes;

  final SessionDataSink inner;
  final void Function(int delta) onAppend;
  int _ackedBytes;

  @override
  String get id => inner.id;

  @override
  Future<int> append(Uint8List bytes) async {
    final length = await inner.append(bytes);
    onAppend(length - _ackedBytes);
    _ackedBytes = length;
    return length;
  }

  @override
  Future<void> close() => inner.close();
}
