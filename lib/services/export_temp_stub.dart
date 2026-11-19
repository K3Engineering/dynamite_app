/// Web (no `dart:io`) stub: the share path hands bytes directly to the plugin,
/// so native temp-file I/O is unreachable.
library;

import 'dart:typed_data';

Future<String> writeTempExportFile(Uint8List bytes, String fileName) =>
    throw UnsupportedError('temp files do not exist on web');
