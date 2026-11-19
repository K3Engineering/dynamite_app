import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

Future<Directory> _exportCacheDirectory() async => Directory(
  '${(await getApplicationCacheDirectory()).path}/dynamite_exports',
);

// Started by main() once; writes wait for it so cleanup cannot unlink a file
// that a just-opened share sheet is about to read.
Future<void>? _startupCleanup;

/// Remove the previous process's share files. Called only at startup: desktop
/// share sheets may still read a file after share_plus's future completes.
Future<void> clearStaleShareExports() =>
    _startupCleanup = _clearStaleShareExports();

Future<void> _clearStaleShareExports() async {
  final root = await _exportCacheDirectory();
  if (!await root.exists()) return;
  await for (final child in root.list()) {
    try {
      await child.delete(recursive: true);
    } catch (_) {
      // One file locked by a share target or antivirus must not prevent the
      // other stale export directories from being reclaimed.
    }
  }
}

/// Write [bytes] under a unique directory in the app-scoped cache and return
/// its path. Unique directories isolate concurrent shares and survive the
/// share call; the next startup's [clearStaleShareExports] removes them.
Future<String> writeTempExportFile(Uint8List bytes, String fileName) async {
  await _startupCleanup;
  final root = await _exportCacheDirectory();
  await root.create(recursive: true);
  final dir = await root.createTemp('share-');
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// Release a completed mobile share's staging file. Android copies it before
/// opening the chooser, and iOS invokes the activity-completion callback only
/// after the selected activity has consumed it. Desktop share targets can
/// outlive their plugin future, so their files remain until startup cleanup.
Future<void> releaseTempExportFile(String path) async {
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    await File(path).delete();
  }
}
