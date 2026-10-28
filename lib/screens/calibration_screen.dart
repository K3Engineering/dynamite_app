import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/board_calibration.dart';
import '../services/ble_link_manager.dart';
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
  const new({super.key, required this.deviceId});

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
          if (board is ProvisionedBoardCalibration &&
              board.calGroup?.namespace == CalNamespace.user) ...[
            const SizedBox(height: 16),
            _revertCard(context),
          ],
          // TODO: surface both calibrations side by side (Factory vs User)
          // and/or their per-point delta, instead of only the effective one.
        ],
      ),
    );
  }

  /// The way back from a User recalibration: delete it, Factory applies again.
  Widget _revertCard(BuildContext context) {
    final link = context.read<BleLinkManager>();
    return Card(
      child: ListTile(
        leading: const Icon(Icons.restore),
        title: const Text('Revert to factory calibration'),
        subtitle: const Text(
          'Deletes the recalibration from the device. The factory calibration '
          'applies again.',
        ),
        onTap: () async {
          final ok = await link.revertUserCalibration();
          if (!context.mounted) return;
          final messenger = ScaffoldMessenger.of(context);
          if (ok) {
            showNoticeSnackBar(
              messenger,
              'Reverted to the factory calibration',
            );
          } else {
            showErrorSnackBar(messenger, 'Could not revert the calibration');
          }
        },
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
            onPressed: () =>
                deliver(downloadDelivery('Download calibration report')),
            icon: const Icon(Icons.download),
            label: const Text('Download'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: fileShareSupportedHere
                ? () => deliver(
                    shareDelivery(
                      'Share calibration report',
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
