import '../models/board_calibration.dart';

// ---------------------------------------------------------------------------
// The calibration feature's text.
// ---------------------------------------------------------------------------

/// The product's trust statement for the calibrated units — a product claim,
/// not per-device data (see the flash schema: the device carries the
/// corrections, the app carries what they add up to).
const String kTrustLineCalibrated =
    'mV/V and force: ±0.5% of reading · mV: nominal chain (~1%)';
const String kTrustLineUncalibrated =
    'Uncalibrated — nominal chain in use; expect ~±1% on electrical units.';

/// The one-sentence answer to "why does the gain correction not match my
/// DMM".
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

/// The headline linearity figure: max |deviation| over the cal points, in
/// µV/V. Null without factory data.
double? maxCalDeviation(ChannelBoardCalibration ch) {
  final d = ch.deviationsUvV;
  if (d == null) return null;
  var m = 0.0;
  for (final v in d) {
    if (v.abs() > m) m = v.abs();
  }
  return m;
}

String fmtUvV(double? uvV) =>
    uvV == null ? '—' : '${uvV > 0 ? '+' : ''}${uvV.toStringAsFixed(3)} µV/V';

/// A table cell in µV/V, signed, without the unit (the units row has it).
String fmtSignedUvV(double uvV) =>
    '${uvV > 0 ? '+' : ''}${uvV.toStringAsFixed(3)}';

String fmtGain(double? fraction) => fraction == null
    ? '—'
    : '${fraction >= 1 ? '+' : ''}${((fraction - 1) * 100).toStringAsFixed(2)}%';

String fmtCounts(double counts) =>
    '${counts >= 0 ? '+' : ''}${counts.toStringAsFixed(1)}';

/// "3 weeks ago" from a `cal.date` string; null when the date is missing or
/// unparseable.
String? calibrationAge(String? isoDate) {
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

/// The Settings row's one-line board-calibration state. Facts only: when
/// calibrated, the flash document's own date; the other two states describe
/// what the app holds (a failed connect-time read, a document without
/// factory data) — never a verdict on the device.
String boardCalibrationStatusLine(BoardCalibration? board) {
  if (board == null) return 'Could not read calibration data';
  if (!board.channels.any((c) => c.isFactoryCalibrated)) {
    return 'Missing factory calibration';
  }
  final age = calibrationAge(board.factoryDate);
  return [
    'Calibrated',
    ?board.factoryDate,
    if (age != null) '($age)',
  ].join(' ');
}

/// The plain-text calibration report (support-email / paste-anywhere
/// artifact): mirrors the on-screen content, plus the 5-point tables.
/// [deviceLabel] names the document's owner for a human reader — the device
/// name when known, else the device id.
String calibrationReport(BoardCalibration board, String deviceLabel) {
  final b = StringBuffer('Dynamite Sampler — board calibration report\n');
  b.writeln('Device: $deviceLabel');
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
  b.writeln(
    'Uncertainty: ±0.5% of reading, from component-specification analysis '
    '— not a traceable calibration. The as-found error figures carry the '
    'same ladder uncertainty; nonlinearity figures are relative within '
    'the ladder and exclude the nominal-chain tolerance.',
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
      'CH ${i + 1}: zero offset ${fmtUvV(ch.zeroOffsetUvV)} · '
      'gain ${fmtGain(ch.sensitivityVsNominal)} vs nominal · '
      'end-point linearity ±${maxCalDeviation(ch)!.toStringAsFixed(3)} µV/V',
    );
    b.writeln(
      '  sensitivity ${ch.sensitivityCountsPerMvV!.toStringAsFixed(0)} '
      'counts/(mV/V) · zero offset ${fmtCounts(ch.offsetCounts)} counts',
    );
    final errors = ch.measuredErrorsUvV;
    final nonlinearities = ch.deviationsUvV!;
    for (int k = 0; k < kCalPointCount; ++k) {
      b.writeln(
        '  ${calConfigLabels[k]}  '
        '${ch.setpoints[k].toStringAsFixed(4)} mV/V  '
        '${ch.readings![k].toStringAsFixed(1)} counts  '
        '${errors != null ? 'error ${fmtSignedUvV(errors[k])} µV/V  ' : ''}'
        'nonlinearity ${fmtSignedUvV(nonlinearities[k])} µV/V',
      );
    }
  }
  return b.toString();
}
