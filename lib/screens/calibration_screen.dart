import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/board_calibration.dart';
import '../services/export_delivery.dart';
import '../services/report_export.dart';
import '../services/share_capability.dart';
import '../services/rig_state.dart';
import '../services/calibration_text.dart';
import '../widgets/calibration_view.dart';

/// The board calibration page: the factory calibration view
/// ([CalibrationView]) plus the export row for the plain-text calibration
/// report.
class CalibrationScreen extends StatelessWidget {
  const CalibrationScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    // Document and device name both follow the link: the flash doc dies
    // with the connection (RigState), and the name is read live off it.
    final (board, deviceName) = context
        .select<RigState, (BoardCalibration?, String)>(
          (r) => (r.boardCalibration, r.connectedDeviceName),
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
            onPressed: () => _runExport(context, () {
              final artifact = calibrationReportArtifact(
                report,
                deviceLabel: label,
              );
              return downloadExport(
                bytes: artifact.bytes,
                fileName: artifact.fileName,
                dialogTitle: 'Download calibration report',
              );
            }),
            icon: const Icon(Icons.download),
            label: const Text('Download'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: fileShareSupportedHere
                ? () => _runExport(context, () {
                    final artifact = calibrationReportArtifact(
                      report,
                      deviceLabel: label,
                    );
                    return shareExport(
                      bytes: artifact.bytes,
                      fileName: artifact.fileName,
                      mimeType: artifact.mimeType,
                      dialogTitle: 'Share calibration report',
                      anchor: _shareAnchor(context),
                    );
                  })
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
  ShareAnchor? _shareAnchor(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox) return null;
    final global = box.localToGlobal(Offset.zero);
    final size = box.size;
    return (
      left: global.dx,
      top: global.dy,
      width: size.width,
      height: size.height,
    );
  }
}
