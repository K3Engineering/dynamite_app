/// Web (no `dart:io`) stubs: the share path hands bytes directly to the
/// plugin, so native temp-file I/O is unreachable and cleanup is a no-op.
library;

import 'dart:typed_data';

Future<void> clearStaleShareExports() async {}

Future<String> writeTempExportFile(Uint8List bytes, String fileName) =>
    throw UnsupportedError('temp files do not exist on web');
