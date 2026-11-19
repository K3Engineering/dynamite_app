import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Writes [bytes] to a fresh temp file named [fileName] in the app's
/// OS-purgeable cache area and returns its path.
///
/// Every share gets its own directory: desktop share sheets may read the
/// path after share_plus's future completes, and concurrent shares must not
/// overwrite or delete each other's files. Cleanup therefore belongs to the
/// OS cache policy, not to completion of the Dart share call.
Future<String> writeTempExportFile(Uint8List bytes, String fileName) async {
  final root = Directory('${(await getTemporaryDirectory()).path}/exports');
  await root.create(recursive: true);
  final dir = await root.createTemp('share-');
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
