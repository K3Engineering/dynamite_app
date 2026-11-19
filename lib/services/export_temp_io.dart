import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<Directory> _exportCacheDirectory() async => Directory(
  '${(await getApplicationCacheDirectory()).path}/dynamite_exports',
);

/// Remove the previous process's share files. Called only at startup: desktop
/// share sheets may still read a file after share_plus's future completes.
Future<void> clearStaleShareExports() async {
  final dir = await _exportCacheDirectory();
  if (await dir.exists()) await dir.delete(recursive: true);
}

/// Write [bytes] under a unique directory in the app-scoped cache and return
/// its path. Unique directories isolate concurrent shares and survive the
/// share call; the next startup's [clearStaleShareExports] removes them.
Future<String> writeTempExportFile(Uint8List bytes, String fileName) async {
  final root = await _exportCacheDirectory();
  await root.create(recursive: true);
  final dir = await root.createTemp('share-');
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
