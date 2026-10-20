/// Handing exported files to the OS: the two delivery paths behind every
/// export action. Two plugins (no single package does both well):
/// [downloadExport] (file_picker save-as / browser download) and [shareExport]
/// (share_plus share sheet). The whole file crosses the platform channel as
/// in-memory bytes. [ExportDelivery] names a path as a value so a screen can
/// write its build-then-deliver flow once; [fullScreenShareAnchor] is the
/// popover anchor for actions without a source widget.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import 'share_capability.dart';
import 'export_temp_stub.dart' if (dart.library.io) 'export_temp_io.dart';

/// A build artifact on its way to the OS: the file bytes, its sanitized
/// name, and its MIME type. What csv_export.dart and report_export.dart
/// produce and every delivery path consumes.
typedef ExportArtifact = ({Uint8List bytes, String fileName, String mimeType});

/// One delivery path ([downloadExport] or [shareExport]) as a value: takes
/// a built artifact, hands it to the OS, returns the user-facing result
/// (null = the user cancelled).
typedef ExportDelivery = Future<String?> Function(ExportArtifact artifact);

/// Anchor rect for the iPad share popover when there is no natural source
/// widget (app-bar menu, button row): the whole screen.
ShareAnchor? fullScreenShareAnchor(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox) return null;
  final global = box.localToGlobal(Offset.zero);
  final size = box.size;
  return (
    left: global.dx,
    top: global.dy,
    width: size.width,
    height: size.height,
  );
}

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

/// Share the export via the platform share sheet. [anchor] positions the iPad
/// popover. Returns a user-facing message, or null when dismissed. Errors are
/// thrown for the caller to surface.
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
