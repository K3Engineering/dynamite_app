/// Web (no `dart:io`) stubs for the temp-file helpers: browsers have no
/// filesystem, and the web export path hands bytes to the plugins directly,
/// so these are never called. See `csv_export_temp_io.dart` for the native
/// implementation and `csv_export.dart` for the conditional import.
library;

import 'dart:typed_data';

Future<String> writeTempCsv(Uint8List bytes, String fileName) =>
    throw UnsupportedError('temp files do not exist on web');

Future<void> deleteTempCsv(String path) =>
    throw UnsupportedError('temp files do not exist on web');
