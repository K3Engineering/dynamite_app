import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/board_calibration.dart';
import '../services/export_delivery.dart';
import '../services/report_export.dart';
import '../services/share_capability.dart';
import '../services/rig_state.dart';
import '../widgets/calibration_text.dart';
import '../widgets/calibration_view.dart';
import '../widgets/snackbars.dart';

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
          // The report needs the chain and (nominal or measured) maps —
          // an unprovisioned unit has nothing to report.
          if (board is ProvisionedBoardCalibration) ...[
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
    ProvisionedBoardCalibration board,
    String deviceName,
  ) {
    // The report's owner label: the device name at flash-read time, falling
    // back to the device id.
    final label = deviceName.isEmpty ? deviceId : deviceName;
    final report = calibrationReport(board, label);

    /// Build the report artifact and hand it to one delivery path
    /// (download or share), surfacing the outcome as a snackbar.
    void deliver(ExportDelivery delivery) => runExportAction(
      context,
      () => delivery(calibrationReportArtifact(report, deviceLabel: label)),
      errorTitle: 'Report export',
    );

    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => runExportAction(context, () async {
              await Clipboard.setData(ClipboardData(text: report));
              return 'Calibration report copied to clipboard';
            }, errorTitle: 'Report export'),
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => deliver(
              (a) => downloadExport(
                bytes: a.bytes,
                fileName: a.fileName,
                dialogTitle: 'Download calibration report',
              ),
            ),
            icon: const Icon(Icons.download),
            label: const Text('Download'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: fileShareSupportedHere
                ? () => deliver(
                    (a) => shareExport(
                      bytes: a.bytes,
                      fileName: a.fileName,
                      mimeType: a.mimeType,
                      dialogTitle: 'Share calibration report',
                      anchor: fullScreenShareAnchor(context),
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
}
