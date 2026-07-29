import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/calibration.dart';
import '../services/rig_state.dart';

/// Settings → Device settings → Board calibration: a read-only view of the
/// CONNECTED device's factory calibration (the 5-point ladder fit per
/// channel).
///
/// Everything here is per-board data, so it comes from the flash-document
/// owner ([RigState.boardCalibrationFor]) — never from the data hub's
/// conversion-side snapshot — and renders only while the document belongs
/// to [deviceId], the connected device. No device / no document / another
/// device's document: a placeholder card, never nominal or stale values
/// presented as real ones.
class BoardCalibrationSection extends StatelessWidget {
  const BoardCalibrationSection({super.key, required this.deviceId});

  /// The connected device this section renders for. Passed in by the
  /// settings tab (which only includes the section while a link is up), so
  /// the section needs no link-manager dependency — and a flash document
  /// belonging to any OTHER device is refused by the ownership query.
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    // One ownership query, decided by the document owner: null means no
    // document this run, or a document belonging to another device. Narrow
    // select: slot edits notify RigState too, but the board instance only
    // changes with a fresh flash read.
    final board = context.select<RigState, BoardCalibration?>(
      (r) => r.boardCalibrationFor(deviceId),
    );
    if (board == null) {
      // The dim "nothing here" affordance: the theme's outline role, as in
      // EmptyPlaceholder — not a raw Material grey.
      return Card(
        child: ListTile(
          leading: Icon(
            Icons.phonelink_erase,
            color: Theme.of(context).colorScheme.outline,
          ),
          title: const Text('No calibration data from the device'),
          subtitle: const Text(
            'The factory calibration is read from the device at connect time.',
          ),
        ),
      );
    }
    final calibrated = board.channels
        .where((c) => c.isFactoryCalibrated)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          calibrated == 0
              ? 'No factory calibration on this device — nominal values in use.'
              : 'Factory calibration'
                    '${board.factoryDate != null ? ' · ${board.factoryDate}' : ''}'
                    ' · $calibrated of ${board.channels.length} channels',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (board.excitationMv != null)
          Text(
            'Factory excitation measurement: ${board.excitationMv} mV',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 8),
        for (int i = 0; i < board.channels.length; i++)
          _ChannelCalTile(index: i, channel: board.channels[i]),
      ],
    );
  }
}

/// One channel's factory calibration: a summary line, expanding to the fit
/// diagnostics and the measured 5-point table.
class _ChannelCalTile extends StatelessWidget {
  const _ChannelCalTile({required this.index, required this.channel});

  final int index;
  final ChannelBoardCalibration channel;

  @override
  Widget build(BuildContext context) {
    final calibrated = channel.isFactoryCalibrated;
    return Card(
      child: ExpansionTile(
        title: Text('Ch ${index + 1}'),
        subtitle: Text(
          calibrated
              ? 'span ${_span(channel)} · offset ${_offset(channel)} · '
                    'NL ${_nl(channel.terminalNonlinearityPpm(positiveSide: true))}'
              : 'Nominal values (no factory data)',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('Source', calibrated ? 'Factory' : 'Nominal fallback'),
                _row('Span', '${_span(channel)} Mcounts/(mV/V)'),
                _row('Offset', '${_offset(channel)} counts'),
                _row(
                  'Effective excitation',
                  '${channel.effectiveExcitationV.toStringAsFixed(4)} V',
                ),
                if (calibrated) ...[
                  _row(
                    'Nonlinearity +FS',
                    _nl(channel.terminalNonlinearityPpm(positiveSide: true)),
                  ),
                  _row(
                    'Nonlinearity −FS',
                    _nl(channel.terminalNonlinearityPpm(positiveSide: false)),
                  ),
                  const SizedBox(height: 8),
                  Table(
                    columnWidths: const {
                      0: FlexColumnWidth(),
                      1: FlexColumnWidth(),
                      2: FlexColumnWidth(),
                    },
                    children: [
                      TableRow(
                        children: [
                          _th(context, 'Config'),
                          _th(context, 'Setpoint (mV/V)'),
                          _th(context, 'Reading (counts)'),
                        ],
                      ),
                      for (int k = 0; k < kCalPointCount; k++)
                        TableRow(
                          children: [
                            _td(calConfigLabels[k]),
                            _td(channel.setpoints[k].toStringAsFixed(4)),
                            _td(channel.readings![k].toStringAsFixed(1)),
                          ],
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _span(ChannelBoardCalibration ch) =>
      (ch.spanCountsPerMvV / 1e6).toStringAsFixed(6);

  static String _offset(ChannelBoardCalibration ch) {
    final o = ch.offsetCounts;
    return '${o >= 0 ? '+' : ''}${o.toStringAsFixed(1)}';
  }

  static String _nl(double ppm) =>
      '${ppm >= 0 ? '+' : ''}${ppm.toStringAsFixed(1)} ppm';

  static Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [Text(label), Text(value)],
    ),
  );

  static Widget _th(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(text, style: Theme.of(context).textTheme.labelSmall),
  );

  static Widget _td(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(text),
  );
}
