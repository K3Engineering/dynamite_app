/// CSV export of a recorded session: builds the dynamite-csv file (its
/// layout is defined by the emitter below and pinned byte-for-byte by
/// test/csv_export_test.dart). Handing it to the OS is export_delivery.dart's
/// job.
///
/// Each row carries an unwrapped, gap-inclusive `ssn` (`ssn_origin + row`);
/// dropped samples and unavailable units emit blank cells, never sentinels or
/// substitutes.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:yaml_writer/yaml_writer.dart';

import '../models/board_calibration.dart';
import '../models/channel_converter.dart';
import '../models/display_unit.dart';
import 'export_names.dart';
import 'session_data.dart';

/// The dynamite-csv format's view of a display unit: the symbol and per-column
/// fixed-point precision.
extension DisplayUnitCsv on DisplayUnit {
  /// The unit's verbatim symbol in a dynamite-csv file: exactly as the
  /// firmware certificates write it — lowercase `raw`, `mV/V` with the
  /// slash — used in header suffixes and the metadata's `converted_unit`.
  /// Differs from [symbol] only for [DisplayUnit.raw] (whose display label
  /// is capitalized).
  String get csvSymbol => this == DisplayUnit.raw ? 'raw' : symbol;

  /// Fixed-point decimals for this unit on the channel behind [conv]: one guard
  /// digit beyond the value of 1 ADC count. Null when the unit can't convert.
  int? exportDecimalsFor(ChannelConverter conv) {
    final quantum = conv.countQuantum(this)?.abs();
    if (quantum == null) return null;
    // The nudge keeps an exact power-of-ten quantum from gaining a spurious
    // extra decimal to floating-point error in the log.
    return (1 - math.log(quantum) / math.ln10 - 1e-9).ceil().clamp(0, 10);
  }
}

/// The session's recorded [data] as a deliverable CSV artifact: the file
/// bytes, its sanitized name, and its MIME type. [unit] is the file's
/// converted unit (the user's pick in the export flow).
/// [sessionName]/[recordedAtIso]/[deviceInfo] are the session's fields, passed
/// flat so the export API doesn't take store types. Delivery is the caller's
/// job (export_delivery.dart).
({Uint8List bytes, String fileName, String mimeType}) buildSessionCsvArtifact({
  required String sessionName,
  required String recordedAtIso,
  required Map<String, Object?> deviceInfo,
  required SessionData data,
  required DisplayUnit unit,
  required String generator,
  bool interrupted = false,
}) {
  final columns = [
    for (int ch = 0; ch < data.channels.length; ch++)
      _column(unit, data.converterFor(ch)),
  ];
  final metadata = _sessionMetadata(
    data: data,
    unit: unit,
    columns: columns,
    recordedAtIso: recordedAtIso,
    generator: generator,
    deviceInfo: deviceInfo,
    interrupted: interrupted,
  );
  final buf = StringBuffer()
    ..writeln('# dynamite-csv 1')
    ..writeln('# ${jsonEncode(metadata)}');
  // The human-glanceable rendering of the same object: line 2 stays the
  // only machine form.
  for (final line in yamlLinesForCsvMetadata(metadata)) {
    buf.writeln('# $line');
  }
  // The encoder joins rows; the file's last line still ends with \n.
  buf
    ..write(_csv.encode(_bodyRows(data, unit, columns)))
    ..writeln();
  return (
    bytes: Uint8List.fromList(utf8.encode(buf.toString())),
    fileName: csvFileNameForSession(sessionName),
    mimeType: 'text/csv',
  );
}

/// One export column's frozen converter and quartet-2 formatter (null when the
/// unit is unavailable). Metadata and cells read the same converter.
typedef _Column = ({
  ChannelConverter converter,
  String Function(int raw)? format,
});

_Column _column(DisplayUnit unit, ChannelConverter converter) =>
    (converter: converter, format: _columnFormatter(unit, converter));

/// The metadata line's JSON object; map order is the emission order.
Map<String, Object?> _sessionMetadata({
  required SessionData data,
  required DisplayUnit unit,
  required List<_Column> columns,
  required String recordedAtIso,
  required String generator,
  required Map<String, Object?> deviceInfo,
  required bool interrupted,
}) {
  final firstBoard = columns[0].converter.calibration.board;
  return {
    'format': 'dynamite-csv',
    'version': 1,
    'generator': generator,
    // Machines use recorded_unix, derived here so the two can't disagree.
    'recorded_at': recordedAtIso,
    'recorded_unix':
        DateTime.parse(recordedAtIso).millisecondsSinceEpoch ~/ 1000,
    'sample_rate_hz': data.sampleRate,
    'ssn_origin': data.ssnOrigin,
    'converted_unit': unit.csvSymbol,
    // Absent when false, so the complete-session shape stays the v1 schema.
    if (interrupted) 'interrupted': true,
    // The recording apparatus: identity, electrical configuration, and board-cal
    // provenance. Descriptive traceability; each channel's board_cal is the
    // operative transfer function.
    'device': {
      ...deviceInfo,
      'afe': {
        'adc_ref_v': firstBoard?.nominals.adcFsrV,
        'front_end_gain': firstBoard?.nominals.afeGain,
        'adc_gain': [
          for (final col in columns)
            col.converter.calibration.board?.nominals.pgaGain,
        ],
        // The excitation the mV columns are scaled by; the only place it
        // appears for a session without board_cal.
        'excitation_v': firstBoard?.displayExcitationV,
      },
      // Raw store provenance; descriptive only. Null on older sessions.
      'kvs': data.deviceKvs?.toJson(),
    },
    'channels': [for (final col in columns) _channelMetadata(col)],
  };
}

/// The body grid: a header row then one row per sample; null cells encode
/// blank (gap rows and unconvertible columns).
///
/// TODO(perf): This materializes the whole grid in memory — the format
/// milestone will replace it with a `sync*` generator feeding
/// `_csv.encoder` one row at a time (see SessionStore.loadSession's own
/// materialization note).
List<List<Object?>> _bodyRows(
  SessionData data,
  DisplayUnit unit,
  List<_Column> columns,
) {
  final n = data.channels.length;
  final rows = <List<Object?>>[
    [
      'ssn',
      for (int ch = 0; ch < n; ch++) 'ch$ch',
      for (int ch = 0; ch < n; ch++) 'ch${ch}_${unit.csvSymbol}',
    ],
  ];
  for (int s = 0; s < data.sampleCount; s++) {
    // ssn is unwrapped and gap-inclusive, so it's a plain arithmetic
    // progression. A gap row blanks both quartets: the buffer holds a held,
    // not real, value.
    final isGap = data.gaps.contains(s);
    rows.add([
      data.ssnOrigin + s,
      for (int ch = 0; ch < n; ch++) isGap ? null : data.channels[ch][s],
      for (int ch = 0; ch < n; ch++)
        isGap ? null : columns[ch].format?.call(data.channels[ch][s]),
    ]);
  }
  return rows;
}

/// The quartet-2 cell formatter for one channel: the converter folded with the
/// column's fixed-point decimals. Null when the unit is unavailable.
String Function(int raw)? _columnFormatter(
  DisplayUnit unit,
  ChannelConverter conv,
) {
  final convert = conv.netMap(unit);
  final decimals = unit.exportDecimalsFor(conv);
  if (convert == null || decimals == null) return null;
  return (raw) => convert(raw.toDouble()).toStringAsFixed(decimals);
}

/// The body-row encoder: `\n` endings, no BOM. Null fields encode blank.
final Csv _csv = Csv(lineDelimiter: '\n');

/// The YAML writer for the metadata block. The comment block is
/// implementation-defined and re-derivable from line 2; [toEncodable] rejects
/// anything outside the JSON-shaped schema.
final YamlWriter _yamlWriter = YamlWriter(
  toEncodable: (object) =>
      throw ArgumentError('no YAML form for ${object.runtimeType}'),
);

/// The YAML rendering of the metadata object, as comment-block lines.
List<String> yamlLinesForCsvMetadata(Map<String, Object?> metadata) =>
    const LineSplitter().convert(_yamlWriter.write(metadata));

/// One `channels[]` entry: the load cell (null = none), the tare in raw counts
/// (null = gross), and the board cal (null when uncalibrated). Calibration is
/// board-uniform.
Map<String, Object?> _channelMetadata(_Column col) {
  final cell = col.converter.calibration.loadCell;
  final board = col.converter.calibration.board;
  return {
    'load_cell': cell == null
        ? null
        : {
            'name': cell.name,
            'capacity_kg': cell.capacityKg,
            'sensitivity_mv_v': cell.sensitivityMvV,
            // Only when true: absent reads as not inverted, keeping files
            // from non-inverted rigs byte-identical to the old format.
            if (cell.inverted) 'inverted': true,
          },
    'tare_raw': col.converter.tare,
    'board_cal': board is CalibratedChannelBoard ? board.toJson() : null,
  };
}

/// The CSV filename for a session: the session name sanitized per
/// [exportFileNameFor].
String csvFileNameForSession(String sessionName) =>
    exportFileNameFor(sessionName, 'csv', fallback: 'session');
