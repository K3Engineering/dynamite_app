import 'dart:io';

import 'package:disk_space_2/disk_space_2.dart';

import '../models/storage_capacity.dart';
import 'database.dart';

/// Native producer for the storage strip (see `storage_capacity.dart`):
/// real free space from disk_space_2 plus the exact database size from
/// SQLite. Android/iOS only — the plugin has no desktop implementations,
/// so other platforms report null and the strip hides.
/// Native app storage is never auto-evicted (isPersistent).
Future<StorageCapacity?> fetchStorageCapacity() async {
  if (!Platform.isAndroid && !Platform.isIOS) return null;
  try {
    final freeMb = await DiskSpace.getFreeDiskSpace;
    if (freeMb == null) return null;
    return StorageCapacity(
      usedBytes: await AppDatabase.instance.databaseFileBytes(),
      availableBytes: (freeMb * 1024 * 1024).round(),
      isPersistent: true,
    );
  } catch (_) {
    return null;
  }
}

/// Native storage needs no persistence request — nothing auto-deletes it.
Future<bool> requestPersistentStorage() async => true;

bool browserMayAutoDeleteSessions() => false;
