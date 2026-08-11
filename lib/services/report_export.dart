/// Calibration-report export: the plain-text report (see
/// `calibration_text.dart`) handed to the OS through the same two delivery
/// paths as session CSV export (see csv_export.dart):
/// - [downloadCalibrationReport] — file_picker's `saveFile`: a save-as
///   dialog on Android/iOS/macOS/Windows/Linux, a browser download on web.
/// - [shareCalibrationReport] — share_plus's share sheet (unsupported on
///   Linux — see [fileShareSupportedHere]).
library;

import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import 'csv_export.dart';
import 'csv_export_temp_stub.dart'
    if (dart.library.io) 'csv_export_temp_io.dart';

/// The report export's file name: `calibration_report_<device label>.txt`,
/// sanitized per the shared export rules ([exportFileNameFor]).
String calibrationReportFileName(String deviceLabel) => exportFileNameFor(
  'calibration_report_$deviceLabel',
  'txt',
  fallback: 'calibration_report',
);

/// Download [report] as a .txt file: a save-as dialog on native platforms,
/// a browser download on web. [deviceLabel] names the file.
///
/// Returns a user-facing result message, or null when the user cancelled —
/// callers should stay silent then. Errors are thrown for the caller to
/// surface.
Future<String?> downloadCalibrationReport({
  required String report,
  required String deviceLabel,
}) async {
  final fileName = calibrationReportFileName(deviceLabel);
  final savedTo = await FilePicker.saveFile(
    dialogTitle: 'Download calibration report',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['txt'],
    bytes: Uint8List.fromList(utf8.encode(report)),
  );
  if (kIsWeb) {
    // The browser handles the download; saveFile always returns null there.
    return 'Download started for $fileName';
  }
  // Null = user cancelled the dialog.
  return savedTo == null ? null : 'Saved to $savedTo';
}

/// Share [report] as a .txt file via the platform share sheet.
/// [sharePositionOrigin] anchors the iPad share popover; ignored elsewhere.
///
/// Returns a user-facing result message, or null when the user dismissed the
/// sheet. The share sheet doesn't say where the file went (or what the user
/// did with it), so the message can't either. Errors are thrown for the
/// caller to surface.
Future<String?> shareCalibrationReport({
  required String report,
  required String deviceLabel,
  Rect? sharePositionOrigin,
}) async {
  final fileName = calibrationReportFileName(deviceLabel);
  final bytes = Uint8List.fromList(utf8.encode(report));
  final XFile file;
  if (kIsWeb) {
    // XFile.name is ignored by most platforms; share_plus's fileNameOverrides
    // is what sets the shared/downloaded file's name.
    file = XFile.fromData(bytes, mimeType: 'text/plain');
  } else {
    file = XFile(await writeTempCsv(bytes, fileName), mimeType: 'text/plain');
  }
  ShareResult result;
  try {
    result = await SharePlus.instance.share(
      ShareParams(
        title: 'Share calibration report',
        files: [file],
        fileNameOverrides: [fileName],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  } finally {
    if (!kIsWeb) await deleteTempCsv(file.path);
  }
  return switch (result.status) {
    ShareResultStatus.success => 'Shared $fileName',
    // Backed out of the share sheet: null = the caller shows no snackbar.
    ShareResultStatus.dismissed => null,
    // The platform can't tell what happened; treat as shared.
    ShareResultStatus.unavailable => 'Shared $fileName (status unknown)',
  };
}
