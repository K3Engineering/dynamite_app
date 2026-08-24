/// Calibration-report export: packaging the plain-text report (content
/// built by services/calibration_text.dart) as a deliverable artifact.
/// Handing the file to the OS (save-as dialog, share sheet) is the caller's
/// composition with export_delivery.dart — this module never touches
/// platform UI.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'export_names.dart';

/// The report export's file name: `calibration_report_<device label>.txt`,
/// sanitized per the shared export rules ([exportFileNameFor]).
String calibrationReportFileName(String deviceLabel) => exportFileNameFor(
  'calibration_report_$deviceLabel',
  'txt',
  fallback: 'calibration_report',
);

/// The plain-text calibration [report] as a deliverable artifact: the file
/// bytes, its sanitized name, and its MIME type. [deviceLabel] names the
/// file. Delivery is the caller's job (export_delivery.dart).
({Uint8List bytes, String fileName, String mimeType}) calibrationReportArtifact(
  String report, {
  required String deviceLabel,
}) => (
  bytes: Uint8List.fromList(utf8.encode(report)),
  fileName: calibrationReportFileName(deviceLabel),
  mimeType: 'text/plain',
);
