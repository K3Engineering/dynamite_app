import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/board_calibration.dart';
import '../services/csv_export.dart' show fileShareSupportedHere;
import '../services/report_export.dart';
import '../services/rig_state.dart';
import '../widgets/calibration_text.dart';
import '../widgets/calibration_view.dart';

/// The board calibration page: the factory calibration view
/// ([CalibrationView], reached from the Settings row) plus the app-bar menu
/// exporting the plain-text calibration report (copy / download / share).
class CalibrationScreen extends StatelessWidget {
  const CalibrationScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final (board, deviceName) = context
        .select<RigState, (BoardCalibration?, String)>(
          (r) => (r.boardCalibrationFor(deviceId), r.deviceNameFor(deviceId)),
        );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Board calibration'),
        actions: [
          if (board != null)
            PopupMenuButton<String>(
              onSelected: (action) =>
                  _onMenuAction(context, action, board, deviceName),
              itemBuilder: (menuContext) => [
                const PopupMenuItem(value: 'copy', child: Text('Copy report')),
                const PopupMenuItem(
                  value: 'download',
                  child: Text('Download report'),
                ),
                PopupMenuItem(
                  value: 'share',
                  enabled: fileShareSupportedHere,
                  child: Text(
                    'Share report'
                    '${fileShareSupportedHere ? '' : ' (not supported here)'}',
                  ),
                ),
              ],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [CalibrationView(deviceId: deviceId)],
      ),
    );
  }

  /// Run one export action and surface its outcome as a snackbar: the
  /// result message, the failure, or nothing when the user cancelled (a
  /// null message). Same pattern as the session screen's CSV actions.
  Future<void> _onMenuAction(
    BuildContext context,
    String action,
    BoardCalibration board,
    String deviceName,
  ) async {
    // The report's owner label: the device name at flash-read time, falling
    // back to the device id.
    final label = deviceName.isEmpty ? deviceId : deviceName;
    final report = calibrationReport(board, label);
    String? message;
    Object? error;
    try {
      message = await switch (action) {
        'copy' => _copyReport(report),
        'download' => downloadCalibrationReport(
          report: report,
          deviceLabel: label,
        ),
        _ => shareCalibrationReport(
          report: report,
          deviceLabel: label,
          sharePositionOrigin: _shareAnchor(context),
        ),
      };
    } catch (e) {
      error = e;
    }
    if (!context.mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Report export failed: $error')));
    } else if (message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<String> _copyReport(String report) async {
    await Clipboard.setData(ClipboardData(text: report));
    return 'Calibration report copied to clipboard';
  }

  /// Anchor rect for the iPad share popover (the whole screen when invoked
  /// from the app-bar menu).
  Rect? _shareAnchor(BuildContext context) {
    final box = context.findRenderObject();
    return box is RenderBox ? box.localToGlobal(Offset.zero) & box.size : null;
  }
}
