/// Handing exported files to the OS: the two delivery paths behind every
/// exporter (session CSV in csv_export.dart, calibration report in
/// report_export.dart), plus the shared export filename rules.
///
/// Two delivery paths, two plugins (no single package does both well):
/// - [downloadExport] — file_picker's `saveFile`: a save-as dialog on
///   Android/iOS/macOS/Windows/Linux, a browser download on web.
/// - [shareExport] — share_plus's share sheet ("Save to Files" on iOS, the
///   Web Share API with download fallback on web). File sharing is
///   unsupported on Linux — see `fileShareSupportedHere` in
///   share_capability.dart.
///
/// Note the whole file crosses the platform channel as in-memory bytes
/// (file_picker's only API); a chunked writer is planned with the CSV format
/// milestone.
library;

import 'dart:ui' show Rect;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import 'export_temp_stub.dart' if (dart.library.io) 'export_temp_io.dart';

/// Screen-position rect for the iPad share popover, in global coordinates
/// (ignored elsewhere). A plain record so the delivery API stays free of
/// `dart:ui`; converted to share_plus's `Rect` type at the plugin boundary.
typedef ShareAnchor = ({double left, double top, double width, double height});

/// Download the export as a save-as dialog on native platforms, a browser
/// download on web.
///
/// Returns a user-facing result message, or null when the user cancelled —
/// callers should stay silent then. Errors are thrown for the caller to
/// surface.
Future<String?> downloadExport({
  required Uint8List bytes,
  required String fileName,
  required String dialogTitle,
}) async {
  final savedTo = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: [fileName.split('.').last],
    bytes: bytes,
  );
  if (kIsWeb) {
    // The browser handles the download; saveFile always returns null there.
    return 'Download started for $fileName';
  }
  // Null = user cancelled the dialog.
  return savedTo == null ? null : 'Saved to $savedTo';
}

/// Share the export via the platform share sheet. [anchor] positions the
/// iPad popover; ignored elsewhere.
///
/// Returns a user-facing result message, or null when the user dismissed the
/// sheet. The share sheet doesn't say where the file went (or what the user
/// did with it), so the message can't either. Errors are thrown for the
/// caller to surface.
Future<String?> shareExport({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
  required String dialogTitle,
  ShareAnchor? anchor,
}) async {
  final XFile file;
  if (kIsWeb) {
    // XFile.name is ignored by most platforms; share_plus's fileNameOverrides
    // is what sets the shared/downloaded file's name.
    file = XFile.fromData(bytes, mimeType: mimeType);
  } else {
    file = XFile(
      await writeTempExportFile(bytes, fileName),
      mimeType: mimeType,
    );
  }
  ShareResult result;
  try {
    result = await SharePlus.instance.share(
      ShareParams(
        title: dialogTitle,
        files: [file],
        fileNameOverrides: [fileName],
        sharePositionOrigin: anchor == null
            ? null
            : Rect.fromLTWH(
                anchor.left,
                anchor.top,
                anchor.width,
                anchor.height,
              ),
      ),
    );
  } finally {
    if (!kIsWeb) await deleteTempExportFile(file.path);
  }
  return switch (result.status) {
    ShareResultStatus.success => 'Shared $fileName',
    // Backed out of the share sheet: null = the caller shows no snackbar.
    ShareResultStatus.dismissed => null,
    // The platform can't tell what happened; treat as shared.
    ShareResultStatus.unavailable => 'Shared $fileName (status unknown)',
  };
}

/// An export file name: [base] with characters that are illegal in
/// Windows/macOS/Android filenames replaced (auto session names contain `:`
/// — e.g. `2026-07-29 14:05:32`), leading dots stripped (they would hide the
/// file on macOS/Linux), trailing dots/spaces trimmed (illegal on Windows),
/// and a Windows reserved device name disambiguated with an underscore —
/// Windows refuses CON, NUL, COM1–COM9, LPT1–LPT9 and friends regardless of
/// extension, so the save dialog would reject the suggested name outright.
/// An empty (or scrubbed-away) base becomes [fallback].
String exportFileNameFor(
  String base,
  String extension, {
  String fallback = 'export',
}) {
  var name = (base.isEmpty ? fallback : base)
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
      .replaceAll(RegExp(r'^\.+'), '')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = fallback;
  // Reserved when followed by the end of the name or an extension dot
  // ("con.txt" is as refused as "con"); keep the name recognizable by
  // marking it right after the reserved word ("con_.txt").
  final reserved = RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?=\.|$)',
    caseSensitive: false,
  ).firstMatch(name);
  if (reserved != null) {
    name = '${reserved[0]}_${name.substring(reserved.end)}';
  }
  return '$name.$extension';
}
