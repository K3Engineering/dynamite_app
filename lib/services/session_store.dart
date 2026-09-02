import 'dart:async';

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

/// The per-session file store. See SessionFilesBackend for the file
/// layout, the tail-only damage model, and the completion marker's write
/// discipline; this class owns the catalog cache and the serialized
/// operation queue on top of it.
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

  /// Wrap a backend FUTURE — a rejecting one exercises the construction-
  /// failure path the shared store can hit in production.
  @visibleForTesting
  factory SessionStore.overFuture(Future<SessionFilesBackend> backend) =>
      SessionStore._(backend);

  final Future<SessionFilesBackend> _backend;

  // -- Catalog and operation ordering ----------------------------------------

  final ValueNotifier<SessionCatalogState> _catalog = ValueNotifier(
    const SessionCatalogLoading(),
  );
  Future<void> _operationTail = Future.value();
  Future<void>? _initialCatalogLoad;

  /// The session the store's own writer is currently recording, if any: set
  /// by [createDataSink], cleared by [touchFinal] or [abortSession]. An
  /// unmarked-but-valid directory classifies as an interrupted recording —
  /// except while the live writer owns it, when it must stay invisible
  /// (a healthy recording in progress is not an interruption). Set and read
  /// only inside the operation queue, so it can never race a scan.
  String? _liveSessionId;

  ValueListenable<SessionCatalogState> get catalog => _catalog;

  /// Byte-size revisions: every append ack plus every catalog publication.
  /// The capacity strip's liveness rides the recording cadence through this.
  final StreamController<void> _bytes = StreamController.broadcast();

  void _bumpBytes() => _bytes.add(null);

  /// The live recording's bytes so far (journal line 1 plus acked data):
  /// the only used-bytes input outside the catalog, since the live dir
  /// never lists. Set by [createDataSink] and every append ack, cleared
  /// by [touchFinal]/[abortSession] (the session lists from then on, so
  /// the catalog's own sizes take over). The ack sets run off the
  /// operation queue; a capacity-strip number needs no stronger ordering.
  int _liveBytes = 0;

  /// The byte-size pulse (append acks included) the capacity strip cues on.
  Stream<void> get byteChanges => _bytes.stream;

  Future<T> _enqueue<T>(
    Future<T> Function(SessionFilesBackend files) operation,
  ) {
    final result = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      final SessionFilesBackend files;
      try {
        files = await _backend;
      } catch (error, stackTrace) {
        // Backend construction is terminal — a store that can't open its
        // root can never do anything. The catalog (Loading until a publish
        // lands) must say so instead of spinning forever.
        _catalog.value = SessionCatalogFailed(error, stackTrace);
        result.completeError(error, stackTrace);
        return;
      }
      try {
        result.complete(await operation(files));
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  StateError _catalogUnavailableError(Object error) =>
      StateError('Session catalog is unavailable: $error');

  void _requireCatalogAvailable() {
    if (_catalog.value case SessionCatalogFailed(:final error)) {
      throw _catalogUnavailableError(error);
    }
  }

  Future<void> ensureCatalogLoaded() {
    // A failed future, not a sync throw: callers swallow it in a catchError
    // and let the Failed state render through the listenable, identically
    // to a publish failure landing after the call.
    if (_catalog.value case SessionCatalogFailed(:final error)) {
      return Future.error(_catalogUnavailableError(error));
    }
    if (_catalog.value is SessionCatalogReady) return Future.value();
    return _initialCatalogLoad ??= _enqueue(_publishCatalog);
  }

  /// Re-read every session directory and republish the catalog. The cache
  /// is derived state, so a full re-read always supersedes the deltas —
  /// this is also a Failed catalog's only way back.
  Future<void> refreshCatalog() => _enqueue(_publishCatalog);

  Future<SessionCatalog> _loadCatalogIfNeeded(SessionFilesBackend files) async {
    if (_catalog.value is SessionCatalogLoading) await _publishCatalog(files);
    _requireCatalogAvailable();
    // A publish either leaves the catalog Ready or throws, and a pre-set
    // Failed threw above — the remaining arm is unreachable.
    return switch (_catalog.value) {
      SessionCatalogReady(:final catalog) => catalog,
      _ => throw StateError('catalog not ready after publish'),
    };
  }

  /// Run [operation] on the serialized queue with the catalog guaranteed
  /// loaded and available, handed to the operation as a value so downstream
  /// availability is the parameter's type, not a re-check. Mutations apply
  /// their own delta to the published catalog (see [_refreshCatalogEntry]);
  /// reads need nothing more.
  Future<T> _withCatalog<T>(
    Future<T> Function(SessionFilesBackend files, SessionCatalog catalog)
    operation,
  ) => _enqueue((files) async {
    final catalog = await _loadCatalogIfNeeded(files);
    return operation(files, catalog);
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
      case final _SessionEntry session:
        sessions.add(
          _summaryFor(
            session.id,
            session.journal,
            session.dataBytes,
            interrupted: session.interrupted,
          ),
        );
        byteSizes[id] = session.byteTotal;
      case final _DamagedEntry damagedEntry:
        damaged.add(damagedEntry.damaged);
        byteSizes[id] = damagedEntry.byteTotal;
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
      _catalog.value = SessionCatalogReady(await _readCatalog(files));
      _bumpBytes();
    } catch (error, stackTrace) {
      _catalog.value = SessionCatalogFailed(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
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
    final sink = await files.createSession(
      newSessionId(),
      metaBytes,
      firstData,
    );
    // The store owns the dir from here until touchFinal/abortSession: while
    // live it is invisible to listings (a recording in progress is not an
    // interrupted one), so no catalog load is forced.
    _liveBytes = metaBytes.length + firstData.length;
    _bumpBytes();
    _liveSessionId = sink.id;
    return NotifyingSessionDataSink._(sink, (ackedDataLength) {
      _liveBytes = metaBytes.length + ackedDataLength;
      _bumpBytes();
    });
  });

  /// Write the completion marker — the ONLY write of it anywhere (see
  /// SessionFilesBackend for the marker's write discipline). finalizeSession
  /// calls this after its persisted-vs-accepted count check passed with no
  /// error latched; anything else gets [abortSession].
  Future<void> touchFinal(String id) => _withCatalog((files, _) async {
    try {
      await files.touchFinal(id);
    } finally {
      // Marker or not, the recording is over: the dir's outcome is whatever
      // the next catalog entry reads off disk, not the store's ownership.
      _liveSessionId = null;
      _liveBytes = 0;
    }
    await _refreshCatalogEntry(files, id);
  });

  /// The writer's finalize latched a failure (a mid-recording write error,
  /// a sink-close failure, or a persisted length that disagrees with the
  /// accepted-frame count): [id] gets NO marker. Drops the store's
  /// in-flight ownership and splices the fresh verdict in, so the
  /// interrupted recording lists immediately.
  Future<void> abortSession(String id) => _withCatalog((files, _) async {
    _liveSessionId = null;
    _liveBytes = 0;
    await _refreshCatalogEntry(files, id);
  });

  // -- Listing and load ------------------------------------------------------

  /// The full directory read. The per-directory sizes folded into the
  /// catalog are free along the way (every classify already stats data.raw
  /// and reads the journal), so the capacity strip never walks the tree
  /// itself.
  Future<SessionCatalog> _readCatalog(SessionFilesBackend files) async {
    final sessions = <SessionSummary>[];
    final damaged = <DamagedSession>[];
    final sizes = <String, int>{};
    for (final id in await files.listDirIds()) {
      final entry = await _classify(files, id);
      switch (entry) {
        case final _SessionEntry session:
          sessions.add(
            _summaryFor(
              session.id,
              session.journal,
              session.dataBytes,
              interrupted: session.interrupted,
            ),
          );
          sizes[id] = session.byteTotal;
        case final _DamagedEntry entry:
          damaged.add(entry.damaged);
          sizes[id] = entry.byteTotal;
        case _UnlistedEntry():
      }
    }
    return SessionCatalog(
      sessions: sessions,
      damaged: damaged,
      byteSizes: sizes,
    );
  }

  Future<_ListedEntry> _classify(SessionFilesBackend files, String id) async {
    // The live recording's data.raw is being appended off this queue, so
    // a stat can catch it mid-append (a partial frame reads as damage) —
    // the live dir never lists, so short-circuit before any I/O.
    if (id == _liveSessionId) return const _UnlistedEntry();
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
    // No completion marker: an interrupted recording — the app crashed,
    // the tab died, or the finalize latched a failure. Every integrity
    // check above already passed, so it loads and exports like a complete
    // session but lists flagged as interrupted; nothing ever promotes it
    // to complete afterwards.
    if (!await files.isFinalized(id)) {
      return _SessionEntry(
        id: id,
        journal: journal,
        dataBytes: dataBytes,
        interrupted: true,
        byteTotal: byteTotal,
      );
    }
    return _SessionEntry(
      id: id,
      journal: journal,
      dataBytes: dataBytes,
      interrupted: false,
      byteTotal: byteTotal,
    );
  }

  SessionSummary _summaryFor(
    String id,
    SessionJournal journal,
    int dataBytes, {
    required bool interrupted,
  }) {
    final meta = journal.meta;
    final edit = journal.effectiveEdit;
    final frames = dataBytes ~/ SessionChunkCodec(meta.channelCount).frameBytes;
    return SessionSummary(
      id: id,
      name: edit.name,
      notes: edit.notes,
      createdAt: sessionIdCreatedAt(id),
      durationMs: frames * 1000 ~/ meta.sampleRate,
      channelCount: meta.channelCount,
      sampleRate: meta.sampleRate,
      displayUnit: meta.displayUnit,
      deviceInfo: meta.deviceInfo,
      recordedAt: meta.recordedAt,
      channelLabels: meta.channelLabels,
      visibleChannels: edit.visibleChannels,
      interrupted: interrupted,
    );
  }

  /// Read a session back: strict journal, whole frames from data.raw,
  /// sentinel runs becoming the [SessionData.gaps] hold-fills. A broken
  /// header, a byte count that doesn't divide into frames, or a frame
  /// shape the write path never produces throws (the detail view renders
  /// it as an error state).
  Future<SessionData> loadSession(String id) => _withCatalog((files, _) async {
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
  ) => _withCatalog((files, _) async {
    final journalBytes = await files.readJournal(id);
    if (journalBytes == null) {
      throw StateError('editSession: no journal for session $id');
    }
    final journal = parseSessionJournal(journalBytes);
    final edit = update(journal.effectiveEdit);
    final append = encodeSessionEdit(edit);
    await files.truncateJournal(id, journal.completeBytes);
    await files.appendJournal(id, append);
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
  /// confirmation. Only the layout's three named files are destroyed (see
  /// SessionFilesBackend.delete).
  Future<void> deleteSession(String id) => _withCatalog((files, _) async {
    await files.delete(id);
    _publishDelta(
      (catalog) => _spliceEntry(catalog, id, const _UnlistedEntry()),
    );
  });

  /// Total bytes of every session file — the native storage strip's "used"
  /// number: the catalog's own sizes plus the live recording's acked bytes
  /// (its dir never lists). Stray files the layout can't name don't count.
  Future<int> usedBytes() =>
      _withCatalog((_, catalog) async => catalog.totalBytes + _liveBytes);
}

sealed class _ListedEntry {
  const _ListedEntry({required this.byteTotal});

  /// The directory's bytes as the classification scan found them (data +
  /// journal; the `final` marker is zero bytes by design).
  final int byteTotal;
}

final class _SessionEntry extends _ListedEntry {
  const _SessionEntry({
    required this.id,
    required this.journal,
    required this.dataBytes,
    required this.interrupted,
    required super.byteTotal,
  });

  final String id;
  final SessionJournal journal;
  final int dataBytes;

  /// Loadable but unvouched: strict journal, whole frames, at least one —
  /// and no completion marker. Everything a complete session is, minus the
  /// finalize's endorsement; the listing flags it permanently instead.
  final bool interrupted;
}

final class _DamagedEntry extends _ListedEntry {
  const _DamagedEntry(this.damaged, {required super.byteTotal});
  final DamagedSession damaged;
}

/// Parseable and data-bearing but unmarked, while the store's own writer
/// still owns it: the in-flight recording's dir, invisible to every listing
/// consumer (its bytes come from the store's live total, not the catalog).
final class _UnlistedEntry extends _ListedEntry {
  const _UnlistedEntry() : super(byteTotal: 0);
}

/// A [SessionDataSink] wrapper reporting every ack's absolute data.raw
/// length, so the store's live byte total tracks the recording and the
/// capacity strip pulses on the recording cadence.
class NotifyingSessionDataSink implements SessionDataSink {
  NotifyingSessionDataSink._(this.inner, this.onAppend);

  final SessionDataSink inner;

  /// Called with the ack's absolute data.raw length after every append.
  final void Function(int ackedDataLength) onAppend;

  @override
  String get id => inner.id;

  @override
  Future<int> append(Uint8List bytes) async {
    final length = await inner.append(bytes);
    onAppend(length);
    return length;
  }

  @override
  Future<void> close() => inner.close();
}
