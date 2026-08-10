import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/calibration.dart';
import '../services/rig_state.dart';
import 'cal_error_plot.dart';

/// The product's trust statement for the calibrated units — a product claim,
/// not per-device data (see the flash schema: the device carries the
/// corrections, the app carries what they add up to).
const String kTrustLineCalibrated =
    'mV/V and force: ±0.5% of reading · mV: nominal chain (~1%)';
const String kTrustLineUncalibrated =
    'Uncalibrated — nominal chain in use; expect ~±1% on electrical units.';

/// The one-sentence answer to "why does the gain correction not match my
/// DMM": shown in the details card so the question never has to be asked.
const String kCorrectionNote =
    'Calibration measures and corrects the product of excitation, gain, '
    'reference, and ladder tolerances — their split is unknowable by design.';

/// Board-wide, in the summary card: correction is not a view mode, it is
/// the instrument.
const String kCorrectionApplied =
    'The full 5-point correction is applied to the live view and saved data.';

/// The µV/V ↔ ppm bridge for users comparing against load-cell datasheets
/// (the cal span brackets a standard 2 mV/V cell's rated output).
const String kUvVToPpmNote =
    'For a 2 mV/V load cell, 1 µV/V = 500 ppm of rated output.';

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
    final calibrated = board.channels.where((c) => c.isFactoryCalibrated).length;
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
/// measured-error plot, the diagnostic rows, and the measured 5-point
/// table with per-point error and end-point nonlinearity.
class _ChannelCalCard extends StatelessWidget {
  const _ChannelCalCard({required this.index, required this.channel});

  final int index;
  final ChannelBoardCalibration channel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final calibrated = channel.isFactoryCalibrated;
    // The measured error needs the nominal chain as its reference; without
    // board constants the plot and the Error column drop out, and the
    // end-point nonlinearity (measured-only) is what remains.
    final errors = channel.measuredErrorsUvV;
    final nonlinearities = channel.deviationsUvV;
    return Card(
      child: ExpansionTile(
        title: Text('CH ${index + 1}'),
        subtitle: Text(
          calibrated
              ? 'zero ${_fmtUvV(channel.zeroBalanceUvV)} · '
                    'gain ${_fmtGain(channel.sensitivityVsNominal)} · '
                    'end-point linearity ±${_maxDeviation(channel)!.toStringAsFixed(3)} µV/V'
              : 'Nominal values (no factory data)',
        ),
        children: [
          if (errors != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Measured error', style: theme.textTheme.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: CalErrorPlot(errorsUvV: errors),
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
                  _row('Zero balance', _fmtUvV(channel.zeroBalanceUvV)),
                  _row(
                    'Gain vs nominal',
                    '${_fmtGain(channel.sensitivityVsNominal)} '
                        '(±FS cal points ÷ nominal chain)',
                  ),
                  _row(
                    'End-point linearity',
                    '±${_maxDeviation(channel)!.toStringAsFixed(3)} µV/V '
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
                            if (errors != null) _td(_fmtSigned(errors[k])),
                            _td(_fmtSigned(nonlinearities![k])),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Nonlinearity: deviation from the end-point line through '
                    '±FS — the ±FS entries are 0 by definition.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
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
/// the correction note, and the copy-report affordance.
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
                onPressed: () => _copyReport(context),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy report'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyReport(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: calibrationReport(board, deviceId)));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Calibration report copied to clipboard')),
      );
    }
  }
}

/// The plain-text calibration report (support-email / paste-anywhere
/// artifact): mirrors the on-screen content, plus the 5-point tables.
String calibrationReport(BoardCalibration board, String deviceId) {
  final b = StringBuffer('Dynamite Sampler — board calibration\n');
  b.writeln('Device: $deviceId');
  if (board.factoryDate != null) b.writeln('Calibrated: ${board.factoryDate}');
  final provenance = [
    ?board.calBoardId,
    ?board.calTool,
    ?board.calOrigin,
    if (board.calTempsC case final t?)
      '${t.dut}/${t.calBoard} °C (DUT/cal board)',
  ];
  if (provenance.isNotEmpty) b.writeln('Provenance: ${provenance.join(' · ')}');
  final n = board.nominals;
  if (n != null) {
    b.writeln(
      'Chain: FSR ${n.adcFsrV} V · AFE ${n.afeGain}× '
      '· PGA ${n.pgaGains.map((g) => '$g×').join('/')} · EXC ${n.excitationV} V',
    );
  }
  b.writeln('Trust: $kTrustLineCalibrated');
  if (board.channels.any((c) => c.isFactoryCalibrated)) {
    b.writeln('Correction: $kCorrectionApplied');
  }
  b.writeln('Note: $kUvVToPpmNote');
  // The report travels without its author, so it carries its definitions.
  b.writeln(
    'Definitions: Error = measured reading via the nominal chain minus '
    'the ladder setpoint (as-found, before correction). Nonlinearity = '
    'deviation from the end-point line through ±FS.',
  );
  if (board.adcConfigDrifted == true) {
    b.writeln('WARNING: ADC gain configuration changed since calibration.');
  }
  for (int i = 0; i < board.channels.length; ++i) {
    final ch = board.channels[i];
    b.writeln();
    if (!ch.isFactoryCalibrated) {
      b.writeln('CH ${i + 1}: nominal values (no factory data)');
      continue;
    }
    b.writeln(
      'CH ${i + 1}: zero balance ${_fmtUvV(ch.zeroBalanceUvV)} · '
      'gain ${_fmtGain(ch.sensitivityVsNominal)} vs nominal · '
      'end-point linearity ±${_maxDeviation(ch)!.toStringAsFixed(3)} µV/V',
    );
    b.writeln(
      '  sensitivity ${ch.sensitivityCountsPerMvV!.toStringAsFixed(0)} '
      'counts/(mV/V) · offset ${_fmtCounts(ch.offsetCounts)} counts',
    );
    final errors = ch.measuredErrorsUvV;
    final nonlinearities = ch.deviationsUvV!;
    for (int k = 0; k < kCalPointCount; ++k) {
      b.writeln(
        '  ${calConfigLabels[k]}  '
        '${ch.setpoints[k].toStringAsFixed(4)} mV/V  '
        '${ch.readings![k].toStringAsFixed(1)} counts  '
        '${errors != null ? 'error ${_fmtSigned(errors[k])} µV/V  ' : ''}'
        'nonlinearity ${_fmtSigned(nonlinearities[k])} µV/V',
      );
    }
  }
  return b.toString();
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

/// The headline linearity figure: max |deviation| over the cal points, in
/// µV/V. Null without factory data.
double? _maxDeviation(ChannelBoardCalibration ch) {
  final d = ch.deviationsUvV;
  if (d == null) return null;
  var m = 0.0;
  for (final v in d) {
    if (v.abs() > m) m = v.abs();
  }
  return m;
}

String _fmtUvV(double? uvV) =>
    uvV == null ? '—' : '${uvV > 0 ? '+' : ''}${uvV.toStringAsFixed(3)} µV/V';

/// A table cell in µV/V, signed, without the unit (the units row has it).
String _fmtSigned(double uvV) =>
    '${uvV > 0 ? '+' : ''}${uvV.toStringAsFixed(3)}';

String _fmtGain(double? fraction) => fraction == null
    ? '—'
    : '${fraction >= 1 ? '+' : ''}${((fraction - 1) * 100).toStringAsFixed(2)}%';

String _fmtCounts(double counts) =>
    '${counts >= 0 ? '+' : ''}${counts.toStringAsFixed(1)}';

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

Widget _td(String text) =>
    Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(text));
