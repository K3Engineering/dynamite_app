import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/calibration.dart';
import '../services/data_hub.dart';

/// Settings → Device settings → Board calibration: a read-only view of the
/// device's factory calibration (the 5-point ladder fit per channel), plus
/// the DMM excitation cross-check. The ratiometric calibration is always
/// authoritative — the DMM reading only verifies the measurement chain.
class BoardCalibrationSection extends StatelessWidget {
  const BoardCalibrationSection({super.key});

  @override
  Widget build(BuildContext context) {
    // Select (not watch): the hub notifies per packet, but the board
    // calibration identity only changes when new factory data arrives.
    final board = context.select<DataHub, BoardCalibration>(
      (h) => h.boardCalibration,
    );
    final settings = context.watch<AppSettings>();
    final calibrated = board.channels
        .where((c) => c.isFactoryCalibrated)
        .length;
    final dmmMv = settings.measuredExcitationMv;

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
        const SizedBox(height: 16),
        Text(
          'Excitation cross-check',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          'The ratiometric calibration is authoritative: a load cell and the '
          'calibration ladder share the same excitation, so it cancels. '
          'Measuring the excitation with a DMM can only verify the chain, '
          'not improve the calibration.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey('dmm$dmmMv'),
          initialValue: dmmMv?.toString() ?? '',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Your DMM excitation reading (mV)',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (s) {
            final trimmed = s.trim();
            if (trimmed.isEmpty) {
              unawaited(settings.setMeasuredExcitationMv(null));
            } else {
              final v = double.tryParse(trimmed);
              if (v != null && v > 0) {
                unawaited(settings.setMeasuredExcitationMv(v));
              }
            }
          },
        ),
        if (dmmMv != null) ...[
          const SizedBox(height: 8),
          for (int i = 0; i < board.channels.length; i++)
            Text(
              'Ch ${i + 1}: implied chain gain error '
              '${_gainErrorPercent(board.channels[i], dmmMv)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
        const SizedBox(height: 16),
        Text('Calibrate', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        const Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: null,
              child: Text('Span with known weight'),
            ),
            OutlinedButton(
              onPressed: null,
              child: Text('Compare to reference'),
            ),
            OutlinedButton(onPressed: null, child: Text('Write to device')),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Calibration wizards are coming soon.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }

  /// (measured span) vs (DMM excitation × nominal chain): the combined AFE
  /// gain + ADC reference error the factory calibration absorbed.
  static String _gainErrorPercent(ChannelBoardCalibration ch, double dmmMv) {
    final expected = countsPerMvAtCellOutput * dmmMv / 1000.0;
    final err = ch.spanCountsPerMvV / expected - 1;
    final pct = err * 100;
    return '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(3)} %';
  }
}

/// One channel's factory calibration: a summary line, expanding to the fit
/// diagnostics and the measured 5-point table.
class _ChannelCalTile extends StatelessWidget {
  const _ChannelCalTile({required this.index, required this.channel});

  final int index;
  final ChannelBoardCalibration channel;

  static const _configLabels = [
    '(t1, t5)',
    '(t2, t4)',
    '(t3, t3)',
    '(t4, t2)',
    '(t5, t1)',
  ];

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
                            _td(_configLabels[k]),
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
