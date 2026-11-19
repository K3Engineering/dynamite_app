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

/// One delivery path ([downloadExport] or [shareExport]) as a value: hands
/// a built artifact to the OS and returns the user-facing result (null =
/// the user cancelled). The context is supplied after async artifact-building,
/// so [shareDelivery] doesn't hide an async context use from the analyzer.
typedef ExportDelivery = Future<String?> Function(
  BuildContext context,
  ExportArtifact artifact,
);

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
    (context, artifact) => downloadExport(artifact, dialogTitle: dialogTitle);

/// [shareExport] as an [ExportDelivery], anchored to the invoking widget.
ExportDelivery shareDelivery(String dialogTitle) =>
    (context, artifact) => shareExport(
      artifact,
      dialogTitle: dialogTitle,
      anchor: shareAnchorFor(context),
    );

/// The invoking widget's global bounds, clipped to the view. Async export
/// flows can scroll or resize their source off-screen while a dialog is open;
/// an invisible (or zero-sized) source anchors to the view's center instead.
@visibleForTesting
ShareAnchor shareAnchorFor(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) {
    throw StateError('A share anchor needs a laid-out render box');
  }
  final view = Offset.zero & MediaQuery.sizeOf(context);
  final source = box.localToGlobal(Offset.zero) & box.size;
  final visible = source.intersect(view);
  final anchor = visible.isEmpty
      ? Rect.fromCenter(center: view.center, width: 2, height: 2)
      : visible;
  return (
    left: anchor.left,
    top: anchor.top,
    width: anchor.width,
    height: anchor.height,
  );
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
  if (savedTo == null) return null;
  final path = savedTo.scheme == 'file'
      ? savedTo.toFilePath(windows: defaultTargetPlatform == .windows)
      : savedTo.toString();
  return 'Saved to $path';
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
  try {
    final result = await SharePlus.instance.share(
      ShareParams(
        title: dialogTitle,
        files: [file],
        fileNameOverrides: [artifact.fileName],
        // An unsupported web share is an error, not a "Shared" snackbar for a
        // download fallback whose data: URI cannot hold large session CSVs.
        downloadFallbackEnabled: false,
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
  } finally {
    await releaseTempExportFile(file.path);
  }
}
