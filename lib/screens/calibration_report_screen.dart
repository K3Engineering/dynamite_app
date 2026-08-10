import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/board_calibration.dart';
import '../services/rig_state.dart';
import '../widgets/calibration_report.dart';

/// The board calibration report on its own page: the plain-text artifact
/// exactly as [calibrationReport] produces it — the same string the copy
/// affordance puts on the clipboard, so page and clipboard can never
/// diverge. The device label is the name at flash-read time, falling back
/// to the device id.
class CalibrationReportScreen extends StatelessWidget {
  const CalibrationReportScreen({super.key, required this.deviceId});

  /// The connected device this report renders for.
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final (board, deviceName) = context
        .select<RigState, (BoardCalibration?, String)>(
          (r) => (r.boardCalibrationFor(deviceId), r.deviceNameFor(deviceId)),
        );
    final label = deviceName.isEmpty ? deviceId : deviceName;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Board calibration report'),
        actions: [
          if (board != null)
            IconButton(
              icon: const Icon(Icons.copy, size: 20),
              tooltip: 'Copy report',
              onPressed: () => _copyReport(context, board, label),
            ),
        ],
      ),
      body: board == null
          // The dim "nothing here" affordance: the theme's outline role, as
          // in EmptyPlaceholder — not a raw Material grey.
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.phonelink_erase,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    title: const Text('No calibration data from the device'),
                    subtitle: const Text(
                      'The factory calibration is read from the device at '
                      'connect time.',
                    ),
                  ),
                ),
              ],
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                calibrationReport(board, label),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ),
    );
  }

  Future<void> _copyReport(
    BuildContext context,
    BoardCalibration board,
    String label,
  ) async {
    await Clipboard.setData(
      ClipboardData(text: calibrationReport(board, label)),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Calibration report copied to clipboard')),
      );
    }
  }
}
