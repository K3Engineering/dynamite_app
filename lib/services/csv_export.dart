/// CSV export of a recorded session: building the dynamite-csv file
/// (docs/csv-format-v1.md) as a deliverable artifact. Handing the file to
/// the OS (save-as dialog, share sheet) is the caller's composition with
/// export_delivery.dart — this module never touches platform UI.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/app_meta.dart';
import '../models/channel_calibration.dart';
import '../models/display_unit.dart';
import 'export_names.dart';
import 'session_data.dart';
import 'session_metadata.dart';

/// The dynamite-csv file format's view of a display unit
/// (docs/csv-format-v1.md): the header/metadata symbol and the per-column
/// fixed-point precision. Kept here, not on the enum — the file format is
/// this service's concern.
extension DisplayUnitCsv on DisplayUnit {
  /// The unit's verbatim symbol in a dynamite-csv file: exactly as the
  /// firmware certificates write it — lowercase `raw`, `mV/V` with the
  /// slash — used in header suffixes and the metadata's `converted_unit`.
  /// Differs from [symbol] only for [DisplayUnit.raw] (whose display label
  /// is capitalized).
  String get csvSymbol => this == DisplayUnit.raw ? 'raw' : symbol;

  /// Fixed-point decimals for this unit on [channel] in a dynamite-csv
  /// file: one guard digit beyond the value of 1 ADC count in this unit
  /// (`ceil(1 − log10(quantum))`, clamped to 0..10), computed from the
  /// recorded board cal's sensitivity. Null exactly when the unit can't
  /// convert on the channel (a force unit with no load cell — the file
  /// column is all-blank, so no precision is needed).
  int? exportDecimalsFor(ChannelCalibration channel) {
    final quantum = countQuantumFor(channel)?.abs();
    if (quantum == null) return null;
    // The nudge keeps an exact power-of-ten quantum from gaining a spurious
    // extra decimal to floating-point error in the log.
    return (1 - math.log(quantum) / math.ln10 - 1e-9)
        .ceil()
        .clamp(0, 10)
        .toInt();
  }
}

/// The session's recorded [data] as a deliverable CSV artifact: the file
/// bytes, its sanitized name, and its MIME type. [unit] is the file's
/// converted unit (the user's pick in the export flow — see
/// docs/csv-format-v1.md). [sessionName]/[recordedAt]/[deviceInfoJson] are
/// the session row's fields, passed flat so the export API doesn't take the
/// drift row type. Delivery is the caller's job (export_delivery.dart).
({Uint8List bytes, String fileName, String mimeType}) buildSessionCsvArtifact({
  required String sessionName,
  required DateTime recordedAt,
  required String deviceInfoJson,
  required SessionData data,
  required DisplayUnit unit,
  required AppMeta appMeta,
}) {
  final csv = buildSessionCsv(
    data,
    unit,
    recordedAt: recordedAt,
    generator: appMeta.generator,
    deviceInfoJson: deviceInfoJson,
  );
  return (
    bytes: Uint8List.fromList(utf8.encode(csv)),
    fileName: csvFileNameForSession(sessionName),
    mimeType: 'text/csv',
  );
}

/// Build the session's CSV in the dynamite-csv v1 format
/// (docs/csv-format-v1.md): a `# dynamite-csv 1` magic line, a one-line
/// metadata JSON carrying everything needed to reproduce the converted
/// columns (frozen recording-time calibration, tares, sample rate, ssn
/// origin, device identity), then the grid of raw + converted columns
/// (`ssn, ch0..chN-1, ch0_<unit>..chN-1_<unit>`).
///
/// [unit] is the file's single converted unit (quartet 2), chosen by the
/// user in the export flow; a channel that can't reach it (a force unit
/// with no load cell assigned) gets an all-blank column. Dropped (gap)
/// samples keep their `ssn` row with every sample cell blank. Values are
/// fixed-point with per-column precision ([DisplayUnit.exportDecimalsFor]);
/// conventions are `\n` endings, no BOM, dot decimals — see the spec.
///
/// [deviceInfoJson] is the session row's frozen `device` block (see
/// [toSessionDeviceMetadata]); null or malformed degrades to all-null
/// placeholders rather than failing the export.
///
/// TODO(perf): the whole CSV is built in memory as one string — the format
/// milestone will replace this with a chunked writer (see
/// SessionStorage.loadSession's own materialization note).
String buildSessionCsv(
  SessionData data,
  DisplayUnit unit, {
  required DateTime recordedAt,
  required String generator,
  String? deviceInfoJson,
}) {
  final int n = data.channels.length;
  // The writer recorded the true device counter at the session's first
  // sample when the row was created.
  final int ssnOrigin = data.ssnOrigin;
  final device = deviceInfoJson == null
      ? toSessionDeviceMetadata(name: null, info: null)
      : fromSessionDeviceMetadata(deviceInfoJson);

  // Per-channel quartet-2 cell formatters, computed once from the session's
  // frozen calibration; each closure folds in the column's fixed-point
  // precision. Null is a force unit on a cell-less channel — an all-blank
  // column (the file's '—'). Damaged calibration metadata blanks the whole
  // converted quartet: its floor (uncalibrated channels) must never produce
  // converted numbers that pose as net measurements (the raw quartet always
  // exports).
  final blankConverted = data.damage.calibration;
  final formatters = [
    for (int ch = 0; ch < n; ch++)
      blankConverted
          ? null
          : _columnFormatter(unit, data.calibrationFor(ch), data.tares[ch]),
  ];

  final buf = StringBuffer()
    ..writeln('# dynamite-csv 1')
    ..writeln(
      '# ${jsonEncode(_metadata(data, unit, ssnOrigin, recordedAt, generator, device))}',
    );

  // Header: ssn, then the raw quartet, then the converted quartet. Header
  // cells only ever contain [A-Za-z0-9_/], so no quoting is ever needed.
  buf.write('ssn');
  for (int ch = 0; ch < n; ch++) {
    buf.write(',ch$ch');
  }
  for (int ch = 0; ch < n; ch++) {
    buf.write(',ch${ch}_${unit.csvSymbol}');
  }
  buf.writeln();

  for (int s = 0; s < data.sampleCount; s++) {
    // ssn is unwrapped and gap-inclusive by construction (dropped samples
    // are kept as blank rows), so it is a plain arithmetic progression.
    buf.write('${ssnOrigin + s}');
    if (data.gaps.contains(s)) {
      // Dropped sample: the buffer holds a fabricated (held) value, so emit
      // blank cells rather than fake data — both quartets, every channel.
      buf.write(',' * (2 * n));
    } else {
      for (int ch = 0; ch < n; ch++) {
        buf.write(',${data.channels[ch][s]}');
      }
      for (int ch = 0; ch < n; ch++) {
        final format = formatters[ch];
        buf.write(format == null ? ',' : ',${format(data.channels[ch][s])}');
      }
    }
    buf.writeln();
  }
  return buf.toString();
}

/// The quartet-2 cell formatter for one channel: [unit]'s converter folded
/// with the column's fixed-point decimals ([DisplayUnit.exportDecimalsFor]).
/// Null exactly when the unit is unavailable on the channel (a force unit
/// with no load cell — the file's all-blank column).
String Function(int raw)? _columnFormatter(
  DisplayUnit unit,
  ChannelCalibration cal,
  double? tare,
) {
  final convert = unit.converterFor(cal, tare);
  final decimals = unit.exportDecimalsFor(cal);
  if (convert == null || decimals == null) return null;
  return (raw) => convert(raw.toDouble()).toStringAsFixed(decimals);
}

/// The metadata line's JSON object (docs/csv-format-v1.md): one compact
/// object, all top-level fields required in v1, nullable subfields emitted
/// as null. Map order here is the emission order (and matches the spec).
Map<String, Object?> _metadata(
  SessionData data,
  DisplayUnit unit,
  int ssnOrigin,
  DateTime recordedAt,
  String generator,
  Map<String, Object?> device,
) {
  final int n = data.channels.length;
  return {
    'format': 'dynamite-csv',
    'version': 1,
    'generator': generator,
    'recorded_at': recordedAt.toUtc().toIso8601String(),
    'sample_rate_hz': data.sampleRate,
    'ssn_origin': ssnOrigin,
    'converted_unit': unit.csvSymbol,
    // Storage-integrity damage disclosures (SessionDamage.warningCodes) —
    // the file states its own defects; consumers MUST NOT silently trust a
    // file carrying these. Optional per the spec's minor-revision rule:
    // absent on healthy sessions.
    if (data.damage.warningCodes.isNotEmpty)
      'warnings': data.damage.warningCodes,
    // Frozen at recording start (the session row's deviceInfoJson); a session
    // without identity (web-recorded serial, unreadable DIS) carries the
    // corresponding nulls.
    'device': device,
    // Descriptive traceability (the hardware configuration in effect); the
    // operative transfer function is each channel's board_cal. Nulls when
    // the board's constants never resolved (raw-only session).
    'afe': {
      'adc_ref_v': data.calibrationFor(0).board.nominals?.adcFsrV,
      'front_end_gain': data.calibrationFor(0).board.nominals?.afeGain,
      'adc_gain': [
        for (int ch = 0; ch < n; ch++)
          data.calibrationFor(ch).board.nominals?.pgaGain,
      ],
    },
    'channels': [
      for (int ch = 0; ch < n; ch++)
        _channelMetadata(data.calibrationFor(ch), data.tares[ch]),
    ],
  };
}

/// One `channels[]` entry: the assigned load cell (null = none), the
/// recording-time tare in raw counts (null = no offset — the channel
/// recorded gross, or the stored tare failed integrity checks), and the
/// factory board cal — null when the channel is uncalibrated (the honesty
/// marker: converted values are nominal-referred). Calibration is
/// board-uniform (all channels calibrated or none — see
/// [BoardCalibration.fromKv]), so the markers agree.
Map<String, Object?> _channelMetadata(ChannelCalibration cal, double? tareRaw) {
  final cell = cal.loadCell;
  final board = cal.board;
  return {
    'load_cell': cell == null
        ? null
        : {
            'name': cell.name,
            'capacity_kg': cell.capacityKg,
            'sensitivity_mv_v': cell.sensitivityMvV,
          },
    'tare_raw': tareRaw,
    'board_cal': board.isFactoryCalibrated ? board.toJson() : null,
  };
}

/// The CSV filename for a session: the session name sanitized per
/// [exportFileNameFor].
String csvFileNameForSession(String sessionName) =>
    exportFileNameFor(sessionName, 'csv', fallback: 'session');
