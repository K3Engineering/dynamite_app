/// Web (no `dart:io`) stubs for the temp-file helpers: browsers have no
/// filesystem, and the web export path hands bytes to the plugins directly,
/// so these are never called. See `export_temp_io.dart` for the native
/// implementation and `export_delivery.dart` for the conditional import.
library;

import 'dart:typed_data';

Future<String> writeTempExportFile(Uint8List bytes, String fileName) =>
    throw UnsupportedError('temp files do not exist on web');

Future<void> deleteTempExportFile(String path) =>
    throw UnsupportedError('temp files do not exist on web');
