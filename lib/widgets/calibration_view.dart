import 'package:material_ui/material_ui.dart';

import '../models/board_calibration.dart';
import 'cal_deviation_plot.dart';
import 'calibration_text.dart';

/// The factory calibration view: identity/traceability, the trust statement,
/// and each channel's measured corrections. Renders the board it's handed —
/// the per-device document gating is the caller's concern.
class CalibrationView extends StatelessWidget {
  const CalibrationView({super.key, required this.board});

  /// The board calibration to render; null shows the unreadable-data
  /// placeholder.
  final BoardCalibration? board;

  @override
  Widget build(BuildContext context) {
    switch (board) {
      case null:
        return Card(
          child: ListTile(
            leading: Icon(
              Icons.phonelink_erase,
              color: Theme.of(context).colorScheme.outline,
            ),
            title: const Text('Could not read calibration data'),
            subtitle: const Text(
              'Calibration is read from the device at connect time — '
              'reconnect to retry.',
            ),
          ),
        );
      case UnprovisionedBoardCalibration():
        // A unit with no board data at all: nothing to show per channel.
        return Card(
          child: ListTile(
            leading: Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: const Text('no board data — unit not provisioned'),
            subtitle: const Text('raw counts only.'),
          ),
        );
      case final ProvisionedBoardCalibration board:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BoardCard(board: board),
            const SizedBox(height: 8),
            for (int i = 0; i < board.channels.length; i++) ...[
              _ChannelCalCard(index: i, channel: board.channels[i]),
              const SizedBox(height: 8),
            ],
          ],
        );
    }
  }
}

/// The board card: this unit's calibration identity, the trust statement,
/// and the conversion chain.
class _BoardCard extends StatelessWidget {
  const _BoardCard({required this.board});

  final ProvisionedBoardCalibration board;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final calibrated = board.isFactoryCalibrated;
    final age = calibrationAge(board.factoryDate);

    final String status;
    if (!calibrated) {
      status = 'No factory calibration — nominal values in use';
    } else {
      final parts = [?board.factoryDate, if (age != null) '($age)'];
      status = 'Calibrated ${parts.join(' ')}'.trimRight();
    }

    final provenance = [
      ?board.calBoardId,
      ?board.calTool,
      ?board.calOrigin,
      if (board.calTempsC case final t?)
        '${t.dut}/${t.calBoard} °C (DUT/cal board)',
    ];

    final nominals = board.nominals;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(status, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              calibrated ? kTrustLineCalibrated : kTrustLineUncalibrated,
              style: theme.textTheme.bodySmall,
            ),
            if (calibrated) ...[
              const SizedBox(height: 4),
              Text(kCorrectionApplied, style: theme.textTheme.bodySmall),
            ],
            if (board.adcConfigDrifted == true) ...[
              const SizedBox(height: 4),
              Text(
                'ADC gain configuration changed since calibration — '
                'the calibration may not apply.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (provenance.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                provenance.join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const Divider(height: 24),
            Text(
              'Chain: FSR ${nominals.adcFsrV} V'
              ' · AFE ${nominals.afeGain}×'
              ' · PGA ${nominals.pgaGains.map((g) => '$g×').join('/')}'
              ' · EXC ${nominals.excitationV} V'
              '${nominals.provenance.isEmpty ? '' : ' (${nominals.provenance.values.toSet().join(', ')})'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(kCorrectionNote, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(kUvVToPpmNote, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// One channel's corrections
class _ChannelCalCard extends StatelessWidget {
  const _ChannelCalCard({required this.index, required this.channel});

  final int index;
  final ChannelBoardCalibration channel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channel = this.channel;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('CH ${index + 1}', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(switch (channel) {
              final CalibratedChannelBoard c =>
                'zero offset ${fmtUvV(c.zeroOffsetUvV)} · '
                    'gain ${fmtGain(c.sensitivityVsNominal)} · '
                    'end-point linearity ±${c.maxDeviationUvV.toStringAsFixed(3)} µV/V',
              _ => 'Nominal values (no factory data)',
            }, style: theme.textTheme.bodySmall),
            if (channel case final CalibratedChannelBoard c) ...[
              const SizedBox(height: 12),
              Text('Nonlinearity', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              CalDeviationPlot(deviationsUvV: c.deviationsUvV),
              const SizedBox(height: 4),
              Text(
                'Deviation from the end-point line through ±FS — gain and '
                'offset removed; the ±FS points are 0 by definition.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            _row('Source', switch (channel) {
              CalibratedChannelBoard() => 'Factory',
              NominalChannelBoard() => 'Nominal fallback',
            }),
            if (channel case final CalibratedChannelBoard c) ...[
              _row('Zero offset', fmtUvV(c.zeroOffsetUvV)),
              _row(
                'Gain vs nominal',
                '${fmtGain(c.sensitivityVsNominal)} '
                    '(±FS cal points ÷ nominal chain)',
              ),
              _row(
                'End-point linearity',
                '±${c.maxDeviationUvV.toStringAsFixed(3)} µV/V '
                    'max deviation',
              ),
              const SizedBox(height: 8),
              _table(context, c),
            ],
          ],
        ),
      ),
    );
  }

  /// The per-config measured-error and nonlinearity table.
  Table _table(BuildContext context, CalibratedChannelBoard cal) {
    final errors = cal.measuredErrorsUvV;
    final nonlinearities = cal.deviationsUvV;
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(),
        1: FlexColumnWidth(),
        2: FlexColumnWidth(),
        3: FlexColumnWidth(),
        4: FlexColumnWidth(),
      },
      children: [
        TableRow(
          children: [
            _th(context, 'Config'),
            _th(context, 'Setpoint'),
            _th(context, 'Reading'),
            _th(context, 'Error'),
            _th(context, 'Nonlinearity'),
          ],
        ),
        TableRow(
          children: [
            _unit(context, ''),
            _unit(context, 'mV/V'),
            _unit(context, 'counts'),
            _unit(context, 'µV/V'),
            _unit(context, 'µV/V'),
          ],
        ),
        for (int k = 0; k < kCalPointCount; k++)
          TableRow(
            children: [
              _td(calConfigLabels[k]),
              _td(cal.setpoints[k].toStringAsFixed(4)),
              _td(cal.readings[k].toStringAsFixed(1)),
              _td(fmtSignedUvV(errors[k])),
              _td(fmtSignedUvV(nonlinearities[k])),
            ],
          ),
      ],
    );
  }
}

Widget _row(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 1),
  child: Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label),
      const SizedBox(width: 16),
      Flexible(child: Text(value, textAlign: TextAlign.end)),
    ],
  ),
);

Widget _th(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 2),
  child: Text(text, style: Theme.of(context).textTheme.labelSmall),
);

/// The secondary header row: units under the [_th] quantity names, subdued.
Widget _unit(BuildContext context, String text) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

Widget _td(String text) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 2),
  child: Text(text),
);
