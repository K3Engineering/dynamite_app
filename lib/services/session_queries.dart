/// The screens' only read/modify path for sessions: the catalog listenable
/// plus the session-level actions (rename, notes, visibility, delete, load).
/// The store's file layout never leaves the service layer.
library;

import 'package:flutter/foundation.dart';

import '../models/session_catalog.dart';
import 'session_data.dart';
import 'session_journal.dart';
import 'session_store.dart';

ValueListenable<SessionCatalogState> sessionCatalogState() =>
    SessionStore.instance.catalog;

Future<void> ensureSessionCatalogLoaded() =>
    SessionStore.instance.ensureCatalogLoaded();

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

Future<void> toggleSessionVisibleChannel(String id, int index) =>
    SessionStore.instance.toggleVisibleChannel(id, index);

/// Delete the session (finalized OR damaged): the only destructive
/// operation in the store, always behind an explicit confirmation.
Future<void> deleteSession(String id) =>
    SessionStore.instance.deleteSession(id);
