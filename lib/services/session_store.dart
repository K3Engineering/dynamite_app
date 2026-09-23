import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/damaged_session.dart';
import '../models/session_catalog.dart';
import '../models/session_summary.dart';
import '../utils/future_chain.dart';
import 'live_session_writer.dart';
import 'session_data.dart';
import 'session_files.dart';
import 'session_id.dart';
import 'session_journal.dart';
import 'session_store_backend.dart';

/// The per-session file store: the catalog cache and serialized operation
/// queue over [SessionFilesBackend] (which owns the file layout and damage
/// model). Recording-side operations ([startSession], [finalizeSession],
/// [createDataSink]) are RecordingController's.
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

  /// Wrap a backend future (a rejecting one exercises the construction-failure
  /// path).
  @visibleForTesting
  factory SessionStore.overFuture(Future<SessionFilesBackend> backend) =>
      SessionStore._(backend);

  final Future<SessionFilesBackend> _backend;

  // -- Catalog and operation ordering ----------------------------------------

  final ValueNotifier<SessionCatalogState> _catalog = ValueNotifier(
    const SessionCatalogLoading(),
  );
  final FutureChain _opQueue = FutureChain();
  Future<void>? _initialCatalogLoad;

  /// The session the store's own writer is recording, if any. Set and read only
  /// inside the operation queue, so it can't race a scan.
  String? _liveSessionId;

  ValueListenable<SessionCatalogState> get catalog => _catalog;

  /// Byte-size revisions: every append ack plus every catalog publication.
  final StreamController<void> _bytes = StreamController.broadcast();

  void _bumpBytes() => _bytes.add(null);

  /// The live recording's bytes so far (journal + acked data): the only
  /// used-bytes input outside the catalog, since the live dir never lists.
  int _liveBytes = 0;

  /// Every revision of [_bytes]; the capacity strip listens here.
  Stream<void> get byteChanges => _bytes.stream;

  Future<T> _enqueue<T>(
    Future<T> Function(SessionFilesBackend files) operation,
  ) => _opQueue.run(() async {
    final SessionFilesBackend files;
    try {
      files = await _backend;
    } catch (error, stackTrace) {
      // Backend construction is terminal; surface it as a Failed catalog
      // instead of spinning on Loading forever.
      _catalog.value = SessionCatalogFailed(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
    return operation(files);
  });

  StateError _catalogUnavailableError(Object error) =>
      StateError('Session catalog is unavailable: $error');

  void _requireCatalogAvailable() {
    if (_catalog.value case SessionCatalogFailed(:final error)) {
      throw _catalogUnavailableError(error);
    }
  }

  Future<void> ensureCatalogLoaded() {
    // A failed future, not a sync throw, so callers can catch it uniformly.
    if (_catalog.value case SessionCatalogFailed(:final error)) {
      return Future.error(_catalogUnavailableError(error));
    }
    if (_catalog.value is SessionCatalogReady) return Future.value();
    return _initialCatalogLoad ??= _enqueue(_publishCatalog);
  }

  /// Re-read every session directory and republish. Also a Failed catalog's
  /// only way back.
  Future<void> refreshCatalog() => _enqueue(_publishCatalog);

  Future<SessionCatalog> _loadCatalogIfNeeded(SessionFilesBackend files) async {
    if (_catalog.value is SessionCatalogLoading) await _publishCatalog(files);
    _requireCatalogAvailable();
    // A publish leaves the catalog Ready or throws; Failed threw above.
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

  /// Re-publish after a mutation whose effect is known exactly; callers run in
  /// the operation queue, so no re-scan is needed.
  void _publishDelta(SessionCatalog Function(SessionCatalog current) update) {
    if (_catalog.value case SessionCatalogReady(:final catalog)) {
      _catalog.value = SessionCatalogReady(update(catalog));
      _bumpBytes();
      return;
    }
    throw StateError('catalog delta requires a ready catalog');
  }

  /// Splice [id]'s freshly classified entry into the catalog. Only one
  /// session's I/O; on failure it falls back to a full publish.
  Future<void> _refreshCatalogEntry(
    SessionFilesBackend files,
    String id,
  ) async {
    _ListedEntry entry;
    try {
      entry = await _classify(files, id);
    } catch (e) {
      debugPrint('Classify failed for session $id, rescanning catalog: $e');
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

  /// Open a new session directory for its first packet: id, dir, journal, and
  /// first data append in one round trip. Called by the writer at its FIRST
  /// write only; a no-data recording leaves no artifact.
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
    // The store owns the dir until touchFinal/abortSession; while live it is
    // invisible to listings, so no catalog load is forced.
    _liveBytes = metaBytes.length + firstData.length;
    _bumpBytes();
    _liveSessionId = sink.id;
    return NotifyingSessionDataSink._(sink, (ackedDataLength) {
      _liveBytes = metaBytes.length + ackedDataLength;
      _bumpBytes();
    });
  });

  /// Write the completion marker (the only write of it anywhere).
  /// finalizeSession calls this after its count check passed; anything else
  /// gets [abortSession].
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

  /// The writer latched a failure: [id] gets no marker. Drops ownership and
  /// splices the fresh (interrupted) verdict in.
  Future<void> abortSession(String id) => _withCatalog((files, _) async {
    _liveSessionId = null;
    _liveBytes = 0;
    await _refreshCatalogEntry(files, id);
  });

  // -- Listing and load ------------------------------------------------------

  /// The full directory read; per-directory sizes fall out of the classify.
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
    // The live dir is being appended off this queue; short-circuit before any
    // I/O so a mid-append stat can't read as damage.
    if (id == _liveSessionId) return const _UnlistedEntry();
    final dataBytes = await files.dataByteLength(id);
    final journalBytes = await files.readJournal(id);
    final hasData = dataBytes > 0;
    final hasMeta = journalBytes != null && journalBytes.isNotEmpty;
    // The `final` marker is zero bytes, so data + journal is the byte total.
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
    // No completion marker: an interrupted recording. It loads and exports
    // like a complete session but lists as interrupted, and is never promoted.
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

  /// Read a session back: strict journal, whole frames from data.raw, sentinel
  /// runs becoming [SessionData.gaps]. Anything malformed throws.
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
      deviceKvs: meta.deviceKvs,
    );
  });

  /// data.raw's bytes verbatim, for the damaged entry's hand-recovery export.
  /// Throws when absent. Rides the queue only for ordering against mutations.
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

  /// Append one whole-snapshot edit line (last complete wins), truncating to
  /// the last complete line first so the new line never lands behind torn
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

  Future<void> renameSession(String id, String name) => editSession(
    id,
    (current) => SessionEdit(
      name: name,
      notes: current.notes,
      visibleChannels: current.visibleChannels,
    ),
  );

  Future<void> setSessionNotes(String id, String notes) => editSession(
    id,
    (current) => SessionEdit(
      name: current.name,
      notes: notes,
      visibleChannels: current.visibleChannels,
    ),
  );

  /// Delete the session directory.
  Future<void> deleteSession(String id) => _withCatalog((files, _) async {
    await files.delete(id);
    _publishDelta(
      (catalog) => _spliceEntry(catalog, id, const _UnlistedEntry()),
    );
  });

  // -- Recording lifecycle ---------------------------------------------------

  /// Start a streaming session from the caller-snapshotted [header]. Pure
  /// construction: the directory is only created by the writer's first packet,
  /// so this never fails and never leaves a data-less artifact. The caller
  /// snapshots everything, so this layer never imports the hub.
  LiveSessionWriter startSession(
    SessionHeader header, {
    required int sourceRingCapacity,
    required void Function(Object error) onWriteError,
  }) {
    return LiveSessionWriter(
      header,
      sourceRingCapacity: sourceRingCapacity,
      onWriteError: onWriteError,
      sinkFactory: (meta, firstData) =>
          createDataSink(meta: meta, firstData: firstData),
    );
  }

  /// Finalize a streaming session: drain the write queue, release the sink,
  /// verify the persisted length against the accepted-frames claim, and write
  /// the completion marker only if every step was clean. Throws on the first
  /// failure; the caller surfaces it, and a failure leaves no marker (the
  /// session lists as interrupted). If no data ever reached storage, there is
  /// nothing to finalize.
  Future<void> finalizeSession({required LiveSessionWriter writer}) async {
    // TODO(known-issue): dart:io file ops have no timeout — a wedged
    // flush() (an ailing disk) hangs finalize, and stopSession with it,
    // forever. Web is covered by SinkWorkerTransport's per-request timeout.
    await writer.flush();
    final run = writer.run;
    // The writer latches the first write error; cleanup folds in only if none
    // latched yet.
    Object? error = writer.writeError;
    try {
      await writer.closeSink();
      if (run != null) {
        // Fail loud on an accepted-vs-persisted mismatch: data.raw must hold
        // exactly the frames the writer counted after the last ack.
        final acked = run.ackedLength;
        final expected = writer.expectedDataBytes;
        if (acked != expected) {
          throw StateError(
            'Session ${run.id}: persisted $acked bytes but counted $expected '
            '— the storage layer dropped samples',
          );
        }
        if (error == null) {
          await touchFinal(run.id);
        }
      }
    } catch (e) {
      error ??= e;
    }
    if (error != null) {
      if (run != null) {
        await abortSession(run.id);
      }
      throw error;
    }
  }

  /// Total bytes of every session file: the catalog's sizes plus the live
  /// recording's acked bytes. Stray files don't count.
  Future<int> usedBytes() =>
      _withCatalog((_, catalog) async => catalog.totalBytes + _liveBytes);
}

sealed class _ListedEntry {
  const _ListedEntry({required this.byteTotal});

  /// The directory's bytes as the scan found them (data + journal).
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

  /// Loadable but unvouched: no completion marker. The listing flags it
  /// permanently.
  final bool interrupted;
}

final class _DamagedEntry extends _ListedEntry {
  const _DamagedEntry(this.damaged, {required super.byteTotal});
  final DamagedSession damaged;
}

/// The store's in-flight recording dir, invisible to listings (its bytes come
/// from the store's live total).
final class _UnlistedEntry extends _ListedEntry {
  const _UnlistedEntry() : super(byteTotal: 0);
}

/// A [SessionDataSink] wrapper reporting every ack's absolute data.raw length,
/// so the store's live byte total tracks the recording.
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
