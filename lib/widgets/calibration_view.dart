import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/calibration.dart';
import '../screens/calibration_report_screen.dart';
import '../services/rig_state.dart';
import 'cal_deviation_plot.dart';
import 'calibration_report.dart';

/// The factory calibration view: identity/traceability, the trust statement,
/// and each channel's measured corrections, in physical units. Host-
/// agnostic content — rendered inline in Settings (the inline host) or on
/// its own page (CalibrationScreen); one of the two hosts survives the
/// bake-off.
///
/// Everything here is per-board data from the flash-document owner
/// ([RigState.boardCalibrationFor]); no device / no document / another
/// device's document renders the placeholder card, never stale values.
class CalibrationView extends StatelessWidget {
  const CalibrationView({super.key, required this.deviceId});

  /// The connected device this view renders for.
  final String deviceId;

  @override
  Widget build(BuildContext context) {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SummaryCard(board: board),
        const SizedBox(height: 8),
        for (int i = 0; i < board.channels.length; i++) ...[
          _ChannelCalCard(index: i, channel: board.channels[i]),
          const SizedBox(height: 8),
        ],
        _DetailsCard(board: board, deviceId: deviceId),
      ],
    );
  }
}

/// The header card: when/what/how this unit was calibrated, the trust
/// statement, and the stale-calibration warning when the ADC config moved.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.board});

  final BoardCalibration board;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final calibrated = board.channels
        .where((c) => c.isFactoryCalibrated)
        .length;
    final age = _calAge(board.factoryDate);

    final String status;
    if (calibrated == 0) {
      status = 'No factory calibration — nominal values in use';
    } else {
      final parts = [
        ?board.factoryDate,
        if (age != null) '($age)',
        if (calibrated < board.channels.length)
          '$calibrated of ${board.channels.length} channels',
      ];
      status = 'Calibrated ${parts.join(' ')}'.trimRight();
    }

    final provenance = [
      ?board.calBoardId,
      ?board.calTool,
      ?board.calOrigin,
      if (board.calTempsC case final t?)
        '${t.dut}/${t.calBoard} °C (DUT/cal board)',
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(status, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              calibrated == 0 ? kTrustLineUncalibrated : kTrustLineCalibrated,
              style: theme.textTheme.bodySmall,
            ),
            if (calibrated > 0) ...[
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
          ],
        ),
      ),
    );
  }
}

/// One channel's corrections: a summary line in µV/V, expanding to the
/// nonlinearity plot, the diagnostic rows, and the measured 5-point
/// table with per-point error and end-point nonlinearity.
class _ChannelCalCard extends StatelessWidget {
  const _ChannelCalCard({required this.index, required this.channel});

  final int index;
  final ChannelBoardCalibration channel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final calibrated = channel.isFactoryCalibrated;
    // The plot and the Nonlinearity column need only the measured points;
    // the Error column additionally needs the nominal chain as its
    // reference, so it alone drops out without board constants.
    final errors = channel.measuredErrorsUvV;
    final nonlinearities = channel.deviationsUvV;
    return Card(
      child: ExpansionTile(
        title: Text('CH ${index + 1}'),
        subtitle: Text(
          calibrated
              ? 'zero offset ${fmtUvV(channel.zeroOffsetUvV)} · '
                    'gain ${fmtGain(channel.sensitivityVsNominal)} · '
                    'end-point linearity ±${maxCalDeviation(channel)!.toStringAsFixed(3)} µV/V'
              : 'Nominal values (no factory data)',
        ),
        children: [
          if (calibrated) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Nonlinearity', style: theme.textTheme.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: CalDeviationPlot(deviationsUvV: nonlinearities!),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Deviation from the end-point line through ±FS — gain and '
                'offset removed; the ±FS points are 0 by definition.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row(
                  'Source',
                  calibrated
                      ? 'Factory'
                      : channel.nominals != null
                      ? 'Nominal fallback'
                      : 'Unavailable (no board constants)',
                ),
                if (calibrated) ...[
                  _row('Zero offset', fmtUvV(channel.zeroOffsetUvV)),
                  _row(
                    'Gain vs nominal',
                    '${fmtGain(channel.sensitivityVsNominal)} '
                        '(±FS cal points ÷ nominal chain)',
                  ),
                  _row(
                    'End-point linearity',
                    '±${maxCalDeviation(channel)!.toStringAsFixed(3)} µV/V '
                        'max deviation',
                  ),
                  const SizedBox(height: 8),
                  Table(
                    columnWidths: {
                      for (int c = 0; c < (errors != null ? 5 : 4); ++c)
                        c: const FlexColumnWidth(),
                    },
                    children: [
                      TableRow(
                        children: [
                          _th(context, 'Config'),
                          _th(context, 'Setpoint'),
                          _th(context, 'Reading'),
                          if (errors != null) _th(context, 'Error'),
                          _th(context, 'Nonlinearity'),
                        ],
                      ),
                      TableRow(
                        children: [
                          _unit(context, ''),
                          _unit(context, 'mV/V'),
                          _unit(context, 'counts'),
                          if (errors != null) _unit(context, 'µV/V'),
                          _unit(context, 'µV/V'),
                        ],
                      ),
                      for (int k = 0; k < kCalPointCount; k++)
                        TableRow(
                          children: [
                            _td(calConfigLabels[k]),
                            _td(channel.setpoints[k].toStringAsFixed(4)),
                            _td(channel.readings![k].toStringAsFixed(1)),
                            if (errors != null) _td(fmtSignedUvV(errors[k])),
                            _td(fmtSignedUvV(nonlinearities![k])),
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
}

/// The engineering card: the resolved conversion chain with its provenance,
/// the correction note, and the entry to the report page.
class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.board, required this.deviceId});

  final BoardCalibration board;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nominals = board.nominals;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Details', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            if (nominals != null)
              Text(
                'Chain: FSR ${nominals.adcFsrV} V'
                ' · AFE ${nominals.afeGain}×'
                ' · PGA ${nominals.pgaGains.map((g) => '$g×').join('/')}'
                ' · EXC ${nominals.excitationV} V'
                '${nominals.provenance.isEmpty ? '' : ' (${nominals.provenance.values.toSet().join(', ')})'}',
                style: theme.textTheme.bodySmall,
              )
            else
              Text(
                '${board.constantsStatus.notice(board.constantsDetail)}'
                ' — raw counts only.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            const SizedBox(height: 8),
            Text(kCorrectionNote, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(kUvVToPpmNote, style: theme.textTheme.bodySmall),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        CalibrationReportScreen(deviceId: deviceId),
                  ),
                ),
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('View calibration report'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "3 weeks ago" from a `cal.date` string; null when the date is missing or
/// unparseable. Coarse on purpose — calibration age is a glance quantity.
String? _calAge(String? isoDate) {
  final d = isoDate == null ? null : DateTime.tryParse(isoDate);
  if (d == null) return null;
  final days = DateTime.now().difference(d).inDays;
  if (days < 1) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  if (days < 60) {
    final weeks = days ~/ 7;
    return weeks == 1 ? '1 week ago' : '$weeks weeks ago';
  }
  if (days < 730) {
    final months = days ~/ 30;
    return months <= 1 ? '1 month ago' : '$months months ago';
  }
  final years = days ~/ 365;
  return years == 1 ? '1 year ago' : '$years years ago';
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
