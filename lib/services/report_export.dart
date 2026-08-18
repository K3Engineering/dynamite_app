/// Calibration-report export: the plain-text report (see
/// `widgets/calibration_text.dart`) handed to the OS via the shared export
/// delivery module (export_delivery.dart — both delivery paths, plus the
/// shared filename rules below).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'export_delivery.dart';
import 'share_capability.dart';

/// The report export's file name: `calibration_report_<device label>.txt`,
/// sanitized per the shared export rules ([exportFileNameFor]).
String calibrationReportFileName(String deviceLabel) => exportFileNameFor(
  'calibration_report_$deviceLabel',
  'txt',
  fallback: 'calibration_report',
);

/// Download [report] as a .txt file: a save-as dialog on native platforms,
/// a browser download on web. [deviceLabel] names the file. Returns per the
/// shared delivery contract ([downloadExport]).
Future<String?> downloadCalibrationReport({
  required String report,
  required String deviceLabel,
}) => downloadExport(
  bytes: Uint8List.fromList(utf8.encode(report)),
  fileName: calibrationReportFileName(deviceLabel),
  dialogTitle: 'Download calibration report',
);

/// Share [report] as a .txt file via the platform share sheet. [anchor]
/// positions the iPad share popover; ignored elsewhere. [deviceLabel] names
/// the file. Returns per the shared delivery contract ([shareExport]).
Future<String?> shareCalibrationReport({
  required String report,
  required String deviceLabel,
  ShareAnchor? anchor,
}) => shareExport(
  bytes: Uint8List.fromList(utf8.encode(report)),
  fileName: calibrationReportFileName(deviceLabel),
  mimeType: 'text/plain',
  dialogTitle: 'Share calibration report',
  anchor: anchor,
);
