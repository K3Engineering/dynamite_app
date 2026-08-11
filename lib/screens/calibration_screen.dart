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
/// ([CalibrationView], reached from the Settings row) plus the export
/// button row for the plain-text calibration report (copy / download /
/// share) — the same on-page pattern as the session screen's CSV export.
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
      appBar: AppBar(title: const Text('Board calibration')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (board != null) ...[
            _exportButtons(context, board, deviceName),
            const SizedBox(height: 16),
          ],
          CalibrationView(deviceId: deviceId),
        ],
      ),
    );
  }

  /// The export row: copy to clipboard, download (save-as dialog / browser
  /// download), and the share sheet wherever the OS has one.
  Widget _exportButtons(
    BuildContext context,
    BoardCalibration board,
    String deviceName,
  ) {
    // The report's owner label: the device name at flash-read time, falling
    // back to the device id.
    final label = deviceName.isEmpty ? deviceId : deviceName;
    final report = calibrationReport(board, label);
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _runExport(context, () async {
              await Clipboard.setData(ClipboardData(text: report));
              return 'Calibration report copied to clipboard';
            }),
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _runExport(
              context,
              () =>
                  downloadCalibrationReport(report: report, deviceLabel: label),
            ),
            icon: const Icon(Icons.download),
            label: const Text('Download'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: fileShareSupportedHere
                ? () => _runExport(
                    context,
                    () => shareCalibrationReport(
                      report: report,
                      deviceLabel: label,
                      sharePositionOrigin: _shareAnchor(context),
                    ),
                  )
                : null,
            icon: const Icon(Icons.share),
            label: const Text('Share'),
          ),
        ),
      ],
    );
  }

  /// Run one export action and surface its outcome as a snackbar: the
  /// result message, the failure, or nothing when the user cancelled (a
  /// null message). Same pattern as the session screen's CSV actions.
  Future<void> _runExport(
    BuildContext context,
    Future<String?> Function() action,
  ) async {
    String? message;
    Object? error;
    try {
      message = await action();
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

  /// Anchor rect for the iPad share popover (the whole screen).
  Rect? _shareAnchor(BuildContext context) {
    final box = context.findRenderObject();
    return box is RenderBox ? box.localToGlobal(Offset.zero) & box.size : null;
  }
}
