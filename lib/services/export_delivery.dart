/// Handing exported files to the OS: the two delivery paths behind every
/// export action. Two plugins (no single package does both well):
/// [downloadExport] (file_picker save-as / browser download) and [shareExport]
/// (share_plus share sheet). The whole file crosses the platform channel as
/// in-memory bytes. [ExportDelivery] names a path as a value so a screen can
/// write its build-then-deliver flow once. Share anchors are resolved when
/// delivery starts, after any asynchronous artifact-building UI has closed.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import 'export_temp_stub.dart' if (dart.library.io) 'export_temp_io.dart';

/// A build artifact on its way to the OS: the file bytes, its sanitized
/// name, and its MIME type. What csv_export.dart, report_export.dart and the
/// damaged-session raw exports produce, and every delivery path consumes.
typedef ExportArtifact = ({Uint8List bytes, String fileName, String mimeType});

/// Screen-position rect for iPad share popovers and macOS share menus, in
/// global coordinates (ignored elsewhere). A plain record so the delivery API
/// stays free of `dart:ui`; converted to share_plus's `Rect` at the boundary.
typedef ShareAnchor = ({double left, double top, double width, double height});

/// One delivery path ([downloadExport] or [shareExport]) as a value: takes
/// a built artifact, hands it to the OS, returns the user-facing result
/// (null = the user cancelled).
typedef ExportDelivery = Future<String?> Function(ExportArtifact artifact);

/// Whether the file-share flow can present a share UI on this platform:
/// share_plus shares files on Android, iOS, macOS, Windows and web, but not
/// Linux.
bool get fileShareSupportedHere {
  if (kIsWeb) return true;
  return defaultTargetPlatform != TargetPlatform.linux &&
      defaultTargetPlatform != TargetPlatform.fuchsia;
}

/// [downloadExport] as an [ExportDelivery]: the save-as dialog's title is the
/// only thing a caller varies.
ExportDelivery downloadDelivery(String dialogTitle) =>
    (artifact) => downloadExport(artifact, dialogTitle: dialogTitle);

/// [shareExport] as an [ExportDelivery], anchored to the center of [context]'s
/// render box. Geometry is read when the artifact is delivered, not when this
/// closure is created: CSV export awaits its unit-picker dialog in between.
ExportDelivery shareDelivery(String dialogTitle, BuildContext context) =>
    (artifact) => shareExport(
      artifact,
      dialogTitle: dialogTitle,
      anchor: _centeredShareAnchor(context),
    );

/// A point-sized rect prevents a full-screen source from excluding every edge
/// an iPad popover could use, and centers the macOS share menu as well.
ShareAnchor _centeredShareAnchor(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox) {
    throw StateError('A share anchor needs a render box');
  }
  final center = box.localToGlobal(box.size.center(Offset.zero));
  return (left: center.dx - 1, top: center.dy - 1, width: 2, height: 2);
}

/// Download the export as a save-as dialog on native platforms, a browser
/// download on web.
///
/// Returns a user-facing result message, or null when the user cancelled —
/// callers should stay silent then. Errors are thrown for the caller to
/// surface.
Future<String?> downloadExport(
  ExportArtifact artifact, {
  required String dialogTitle,
}) async {
  final savedTo = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: artifact.fileName,
    bytes: artifact.bytes,
    mimeType: artifact.mimeType,
  );
  if (kIsWeb) {
    // The browser handles the download; saveFile always returns null there.
    return 'Download started for ${artifact.fileName}';
  }
  // Null = user cancelled the dialog.
  return savedTo == null ? null : 'Saved to $savedTo';
}

/// Share the export via the platform share sheet. [anchor] positions iPad
/// popovers and macOS share menus. Returns a user-facing message, or null when
/// dismissed. Errors are thrown for the caller to surface.
Future<String?> shareExport(
  ExportArtifact artifact, {
  required String dialogTitle,
  required ShareAnchor anchor,
}) async {
  final XFile file;
  if (kIsWeb) {
    // XFile.name is ignored by most platforms; share_plus's fileNameOverrides
    // is what sets the shared/downloaded file's name.
    file = XFile.fromData(artifact.bytes, mimeType: artifact.mimeType);
  } else {
    file = XFile(
      await writeTempExportFile(artifact.bytes, artifact.fileName),
      mimeType: artifact.mimeType,
    );
  }
  final result = await SharePlus.instance.share(
    ShareParams(
      title: dialogTitle,
      files: [file],
      fileNameOverrides: [artifact.fileName],
      sharePositionOrigin: Rect.fromLTWH(
        anchor.left,
        anchor.top,
        anchor.width,
        anchor.height,
      ),
    ),
  );
  return switch (result.status) {
    ShareResultStatus.success => 'Shared ${artifact.fileName}',
    // Backed out of the share sheet: null = the caller shows no snackbar.
    ShareResultStatus.dismissed => null,
    // The platform can't tell what happened; treat as shared.
    ShareResultStatus.unavailable =>
      'Shared ${artifact.fileName} (status unknown)',
  };
}
