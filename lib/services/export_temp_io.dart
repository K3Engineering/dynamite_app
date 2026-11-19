import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<Directory> _exportCacheDirectory() async => Directory(
  '${(await getApplicationCacheDirectory()).path}/dynamite_exports',
);

/// Write [bytes] under a unique directory in the app-scoped cache and return
/// its path. Unique directories isolate concurrent shares. Files survive the
/// share call because desktop share targets may read them after its future
/// completes; reclamation belongs to OS cache management.
Future<String> writeTempExportFile(Uint8List bytes, String fileName) async {
  final root = await _exportCacheDirectory();
  await root.create(recursive: true);
  final dir = await root.createTemp('share-');
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
