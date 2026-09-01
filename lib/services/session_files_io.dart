import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'session_store_backend.dart';

/// dart:io implementation of the file layout (see SessionFilesBackend):
/// `documents/sessions/<id>/` holding `meta`, `data.raw`, `final`.
Future<SessionFilesBackend> createBackend() async {
  final docs = await getApplicationDocumentsDirectory();
  await dropLegacySessionDatabase(docs.path);
  return IoSessionFilesBackend('${docs.path}/sessions');
}

/// Drop the replaced SQLite session store if the upgrade left one behind:
/// pre-release dev data, wiped by schema bumps already, so there is nothing
/// to migrate. Best-effort — a file the platform still holds (Windows can
/// lock fresh files) is harmless litter, not something startup should die
/// over.
Future<void> dropLegacySessionDatabase(String documentsPath) async {
  try {
    await for (final entry in Directory(documentsPath).list()) {
      if (entry is File &&
          entry.uri.pathSegments.last.startsWith('dynamite_sessions')) {
        await entry.delete();
      }
    }
  } catch (e) {
    debugPrint('Legacy session database drop failed: $e');
  }
}

/// No sync handles on dart:io — the hot-restart terminate hook is web-only.
void terminateSinkWorker() {}

class IoSessionFilesBackend implements SessionFilesBackend {
  IoSessionFilesBackend(this.root);

  /// Absolute path of the sessions root directory.
  final String root;

  Directory _dir(String id) => Directory('$root/$id');
  File _journal(String id) => File('$root/$id/$sessionJournalFile');
  File _data(String id) => File('$root/$id/$sessionDataFile');
  File _final(String id) => File('$root/$id/$sessionFinalFile');

  @override
  Future<SessionDataSink> createSession(
    String id,
    Uint8List metaBytes,
    Uint8List firstData,
  ) async {
    final dir = _dir(id);
    // A collision (same second AND same random suffix) must never silently
    // merge two recordings into one directory.
    if (await dir.exists()) {
      throw StateError('session directory $id already exists');
    }
    await dir.create(recursive: true);
    final journal = await _journal(id).open(mode: FileMode.write);
    try {
      await journal.writeFrom(metaBytes);
      await journal.flush();
    } finally {
      await journal.close();
    }
    final data = await _data(id).open(mode: FileMode.write);
    try {
      await data.writeFrom(firstData);
      await data.flush();
      return _IoSessionDataSink(id, data);
    } catch (e) {
      await data.close();
      rethrow;
    }
  }

  @override
  Future<List<String>> listDirIds() async {
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return const [];
    final ids = <String>[];
    await for (final entry in rootDir.list()) {
      // A Directory's URI ends in a separator, so the name is the segment
      // before the trailing empty one.
      if (entry is Directory) {
        final segments = entry.uri.pathSegments;
        ids.add(segments[segments.length - 2]);
      }
    }
    return ids;
  }

  @override
  Future<Uint8List?> readJournal(String id) => _readOrNull(_journal(id));

  @override
  Future<Uint8List?> readData(String id) => _readOrNull(_data(id));

  Future<Uint8List?> _readOrNull(File file) async =>
      await file.exists() ? file.readAsBytes() : null;

  @override
  Future<int> dataByteLength(String id) async {
    final file = _data(id);
    return await file.exists() ? file.length() : 0;
  }

  @override
  Future<bool> isFinalized(String id) => _final(id).exists();

  @override
  Future<void> touchFinal(String id) => _final(id).create();

  @override
  Future<void> truncateJournal(String id, int bytes) async {
    final handle = await _journal(id).open(mode: FileMode.append);
    try {
      await handle.truncate(bytes);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> appendJournal(String id, Uint8List bytes) async {
    final handle = await _journal(id).open(mode: FileMode.append);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> delete(String id) async {
    // Refuse BEFORE destroying anything: an entry this layout never wrote
    // means the directory isn't purely ours, so the delete fails with the
    // session still whole — not after its files are already gone.
    const known = {sessionJournalFile, sessionDataFile, sessionFinalFile};
    await for (final entry in _dir(id).list()) {
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (entry is! File || !known.contains(name)) {
        throw FileSystemException(
          'session directory $id holds an entry the layout never wrote',
          entry.path,
        );
      }
    }
    for (final file in [_final(id), _data(id), _journal(id)]) {
      if (await file.exists()) await file.delete();
    }
    await _dir(id).delete();
  }
}

class _IoSessionDataSink implements SessionDataSink {
  _IoSessionDataSink(this.id, this._handle);

  @override
  final String id;

  final RandomAccessFile _handle;

  @override
  Future<int> append(Uint8List bytes) async {
    await _handle.writeFrom(bytes);
    await _handle.flush();
    return _handle.length();
  }

  @override
  Future<void> close() => _handle.close();
}
