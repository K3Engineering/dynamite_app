/// CSV export of a recorded session: builds the dynamite-csv file
/// (docs/csv-format-v2.md). Handing it to the OS is export_delivery.dart's job.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:yaml_writer/yaml_writer.dart';

import '../models/app_meta.dart';
import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';
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
    return (1 - math.log(quantum) / math.ln10 - 1e-9)
        .ceil()
        .clamp(0, 10)
        .toInt();
  }
}

/// The session's recorded [data] as a deliverable CSV artifact: the file
/// bytes, its sanitized name, and its MIME type. [unit] is the file's
/// converted unit (the user's pick in the export flow).
/// [sessionName]/[recordedAtIso]/[deviceInfo] are
/// the session's fields, passed flat so the export API doesn't take store
/// types. Delivery is the caller's job (export_delivery.dart).
({Uint8List bytes, String fileName, String mimeType}) buildSessionCsvArtifact({
  required String sessionName,
  required String recordedAtIso,
  required Map<String, Object?> deviceInfo,
  required SessionData data,
  required DisplayUnit unit,
  required AppMeta appMeta,
  bool interrupted = false,
}) {
  final csv = SessionCsvExport(
    data,
    unit,
    recordedAtIso: recordedAtIso,
    generator: appMeta.generator,
    deviceInfo: deviceInfo,
    interrupted: interrupted,
  ).encode();
  return (
    bytes: Uint8List.fromList(utf8.encode(csv)),
    fileName: csvFileNameForSession(sessionName),
    mimeType: 'text/csv',
  );
}

/// One export column's frozen facts: the recording-time calibration, the frozen
/// tare, and the quartet-2 formatter (null when the unit is unavailable).
typedef _Column = ({
  ChannelCalibration cal,
  double? tare,
  String Function(int raw)? format,
});

/// One session's export in the dynamite-csv format: the recorded [data] frozen
/// with the export-time context ([unit], provenance strings). The file is a
/// magic line, a metadata JSON line, the same metadata re-rendered as YAML
/// comments, then the grid of raw + converted columns. Gap rows keep their
/// `ssn` with blank sample cells.
///
/// TODO(perf): [rows] materializes the whole grid in memory — the format
/// milestone will replace it with a `sync*` generator feeding
/// `_csv.encoder` one row at a time (see SessionStore.loadSession's own
/// materialization note).
class SessionCsvExport {
  SessionCsvExport(
    this.data,
    this.unit, {
    required this.recordedAtIso,
    required this.generator,
    required this.deviceInfo,
    this.interrupted = false,
  });

  final SessionData data;

  /// The file's single converted unit; an unconvertible channel gets a blank
  /// column.
  final DisplayUnit unit;

  /// The session's frozen `recorded_at`; `recorded_unix` derives from it here.
  final String recordedAtIso;

  /// The app version stamp.
  final String generator;

  /// The session's frozen device-identity block.
  final Map<String, Object?> deviceInfo;

  /// The recording never completed; emitted as the additive metadata key
  /// `interrupted`. Every byte is valid, but the tail may be missing.
  final bool interrupted;

  int get _n => data.channels.length;

  /// Per-column frozen facts, derived once.
  late final List<_Column> _columns = [
    for (int ch = 0; ch < _n; ch++)
      (
        cal: data.calibrationFor(ch),
        tare: data.tares[ch],
        format: _columnFormatter(unit, data.converterFor(ch)),
      ),
  ];

  /// The metadata line's JSON object; map order is the emission order.
  late final Map<String, Object?> metadata = {
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
        'adc_ref_v': _columns[0].cal.board?.nominals.adcFsrV,
        'front_end_gain': _columns[0].cal.board?.nominals.afeGain,
        'adc_gain': [
          for (final col in _columns) col.cal.board?.nominals.pgaGain,
        ],
        // The excitation the mV columns are scaled by; the only place it
        // appears for a session without board_cal.
        'excitation_v': _columns[0].cal.board?.displayExcitationV,
      },
      // Raw store provenance; descriptive only. Null on older sessions.
      'kvs': data.deviceKvs?.toJson(),
    },
    'channels': [for (final col in _columns) _channelMetadata(col)],
  };

  /// The body grid: a header row then one row per sample; null cells encode
  /// blank (gap rows and unconvertible columns).
  List<List<Object?>> get rows {
    final rows = <List<Object?>>[
      [
        'ssn',
        for (int ch = 0; ch < _n; ch++) 'ch$ch',
        for (int ch = 0; ch < _n; ch++) 'ch${ch}_${unit.csvSymbol}',
      ],
    ];
    for (int s = 0; s < data.sampleCount; s++) {
      // ssn is unwrapped and gap-inclusive, so it's a plain arithmetic
      // progression. A gap row blanks both quartets: the buffer holds a held,
      // not real, value.
      final isGap = data.gaps.contains(s);
      rows.add([
        data.ssnOrigin + s,
        for (int ch = 0; ch < _n; ch++) isGap ? null : data.channels[ch][s],
        for (int ch = 0; ch < _n; ch++)
          isGap ? null : _columns[ch].format?.call(data.channels[ch][s]),
      ]);
    }
    return rows;
  }

  /// The whole file as one string.
  String encode() {
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
      ..write(_csv.encode(rows))
      ..writeln();
    return buf.toString();
  }
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
  final cell = col.cal.loadCell;
  final board = col.cal.board;
  return {
    'load_cell': cell == null
        ? null
        : {
            'name': cell.name,
            'capacity_kg': cell.capacityKg,
            'sensitivity_mv_v': cell.sensitivityMvV,
          },
    'tare_raw': col.tare,
    'board_cal': board is CalibratedChannelBoard ? board.toJson() : null,
  };
}

/// The CSV filename for a session: the session name sanitized per
/// [exportFileNameFor].
String csvFileNameForSession(String sessionName) =>
    exportFileNameFor(sessionName, 'csv', fallback: 'session');
