import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Writes [bytes] to a fresh temp file named [fileName] in the app's
/// OS-purgeable cache area and returns its path.
///
/// The export cache directory is swept before every write, so at most the
/// in-flight export file lives there: previous exports' temp files can't
/// accumulate if the app died between export and cleanup.
Future<String> writeTempExportFile(Uint8List bytes, String fileName) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/exports');
  await dir.create(recursive: true);
  await for (final stale in dir.list()) {
    try {
      await stale.delete();
    } catch (_) {
      // A file that can't be deleted (locked, raced) must not block export.
    }
  }
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// Best-effort delete of a temp export file after the save/share flow has
/// completed. Failures are ignored: the file is in the OS-purgeable cache
/// area and the next [writeTempExportFile] sweep removes it anyway.
Future<void> deleteTempExportFile(String path) async {
  try {
    await File(path).delete();
  } catch (_) {}
}
