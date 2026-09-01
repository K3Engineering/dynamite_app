/// The screens' only read/modify path for sessions: a catalog stream plus the
/// session-level actions (rename, notes, visibility, delete, load). The
/// store's file layout never leaves the service layer.
library;

import 'dart:typed_data';

import '../models/session_catalog.dart';
import '../models/session_summary.dart';
import 'session_data.dart';
import 'session_journal.dart';
import 'session_store.dart';

/// Sessions, damaged entries, and byte sizes from one directory scan.
Stream<SessionCatalog> watchSessionCatalog() =>
    SessionStore.instance.watch(SessionStore.instance.sessionCatalog);

/// One session, reactively — name, notes, and per-session channel
/// visibility surface here as edits land.
Stream<SessionSummary?> watchSessionSummary(String id) =>
    SessionStore.instance.watch(() => SessionStore.instance.sessionSummary(id));

/// Fetch a session by id (null when gone or no longer loadable).
Future<SessionSummary?> sessionSummaryById(String id) =>
    SessionStore.instance.sessionSummary(id);

/// Total bytes under the sessions root — the native capacity strip's used
/// portion.
Future<int> sessionsUsedBytes() => SessionStore.instance.usedBytes();

/// The byte-size pulse (append acks included) the capacity strip cues on.
Stream<void> sessionByteChanges() => SessionStore.instance.byteChanges;

/// Read a finalized session back for the detail view / CSV export. Throws
/// on unreadable metadata or impossible frame shapes — the detail screen
/// renders failures as an error state.
Future<SessionData> loadSession(String id) =>
    SessionStore.instance.loadSession(id);

/// A damaged entry's data.raw verbatim (for hand recovery); throws when
/// absent.
Future<Uint8List> damagedDataBytes(String id) =>
    SessionStore.instance.rawDataBytes(id);

/// A damaged entry's journal verbatim (for eyeball recovery of
/// calibration/tares); throws when absent.
Future<Uint8List> damagedMetadataBytes(String id) =>
    SessionStore.instance.rawJournalBytes(id);

Future<void> renameSession(String id, String name) =>
    SessionStore.instance.editSession(
      id,
      (current) => SessionEdit(
        name: name,
        notes: current.notes,
        visibleChannels: current.visibleChannels,
      ),
    );

Future<void> setSessionNotes(String id, String notes) =>
    SessionStore.instance.editSession(
      id,
      (current) => SessionEdit(
        name: current.name,
        notes: notes,
        visibleChannels: current.visibleChannels,
      ),
    );

Future<void> setSessionVisibleChannels(String id, List<bool> visible) =>
    SessionStore.instance.editSession(
      id,
      (current) => SessionEdit(
        name: current.name,
        notes: current.notes,
        visibleChannels: visible,
      ),
    );

/// Delete the session (finalized OR damaged): the only destructive
/// operation in the store, always behind an explicit confirmation.
Future<void> deleteSession(String id) =>
    SessionStore.instance.deleteSession(id);
