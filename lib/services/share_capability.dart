/// The vocabulary of the share_plus-backed file-share flow
/// (`shareSessionCsv` in csv_export.dart, `shareCalibrationReport` in
/// report_export.dart) that screens need without importing an export
/// module: the platform capability ([fileShareSupportedHere], to gate a
/// Share button) and the iPad popover anchor ([ShareAnchor]).
library;

import 'package:flutter/foundation.dart';

/// Screen-position rect for the iPad share popover, in global coordinates
/// (ignored elsewhere). A plain record so the delivery API stays free of
/// `dart:ui`; converted to share_plus's `Rect` type at the plugin boundary.
typedef ShareAnchor = ({double left, double top, double width, double height});

/// Whether the file-share flow can present a share UI on this platform:
/// share_plus shares files on Android, iOS, macOS, Windows and web, but not
/// Linux.
bool get fileShareSupportedHere {
  if (kIsWeb) return true;
  return defaultTargetPlatform != TargetPlatform.linux &&
      defaultTargetPlatform != TargetPlatform.fuchsia;
}
