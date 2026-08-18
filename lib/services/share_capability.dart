/// Platform capability of the share_plus-backed file-share flow
/// (`shareSessionCsv` in csv_export.dart, `shareCalibrationReport` in
/// report_export.dart). Kept out of the export services so a screen that
/// only needs to gate its Share button doesn't import an export module.
library;

import 'package:flutter/foundation.dart';

/// Whether the file-share flow can present a share UI on this platform:
/// share_plus shares files on Android, iOS, macOS, Windows and web, but not
/// Linux.
bool get fileShareSupportedHere {
  if (kIsWeb) return true;
  return defaultTargetPlatform != TargetPlatform.linux &&
      defaultTargetPlatform != TargetPlatform.fuchsia;
}
