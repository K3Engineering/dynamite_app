import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/board_calibration.dart';
import '../services/csv_export.dart' show fileShareSupportedHere;
import '../services/report_export.dart';
import '../services/rig_state.dart';
import '../widgets/calibration_text.dart';
import '../widgets/calibration_view.dart';

/// The board calibration page: the factory calibration view
/// ([CalibrationView]) plus the export row for the plain-text calibration
/// report.
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
          CalibrationView(board: board),
        ],
      ),
    );
  }

  /// The export row.
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

  /// Run one export action and surface its outcome as a snackbar; a null
  /// message means the user cancelled, so nothing shows.
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
