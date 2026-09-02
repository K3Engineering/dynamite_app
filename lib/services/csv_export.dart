/// CSV export of a recorded session: building the dynamite-csv file
/// (csv-format-v1.md) as a deliverable artifact. Handing the file to
/// the OS (save-as dialog, share sheet) is the caller's composition with
/// export_delivery.dart — this module never touches platform UI.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/app_meta.dart';
import '../models/channel_calibration.dart';
import '../models/channel_converter.dart';
import '../models/display_unit.dart';
import 'export_names.dart';
import 'session_data.dart';
import 'session_metadata.dart';

/// The dynamite-csv file format's view of a display unit
/// (csv-format-v1.md): the header/metadata symbol and the per-column
/// fixed-point precision. Kept here, not on the enum — the file format is
/// this service's concern.
extension DisplayUnitCsv on DisplayUnit {
  /// The unit's verbatim symbol in a dynamite-csv file: exactly as the
  /// firmware certificates write it — lowercase `raw`, `mV/V` with the
  /// slash — used in header suffixes and the metadata's `converted_unit`.
  /// Differs from [symbol] only for [DisplayUnit.raw] (whose display label
  /// is capitalized).
  String get csvSymbol => this == DisplayUnit.raw ? 'raw' : symbol;

  /// Fixed-point decimals for this unit on the channel behind [conv] in a
  /// dynamite-csv file: one guard digit beyond the value of 1 ADC count in
  /// this unit (`ceil(1 − log10(quantum))`, clamped to 0..10), computed
  /// from the recorded board cal's sensitivity. Null exactly when the unit
  /// can't convert on the channel (a force unit with no load cell — the
  /// file column is all-blank, so no precision is needed).
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
/// converted unit (the user's pick in the export flow — see
/// csv-format-v1C.md). [sessionName]/[recordedAtIso]/[deviceInfo] are
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
  final csv = buildSessionCsv(
    data,
    unit,
    recordedAtIso: recordedAtIso,
    generator: appMeta.generator,
    deviceInfo: deviceInfo,
    interrupted: interrupted,
  );
  return (
    bytes: Uint8List.fromList(utf8.encode(csv)),
    fileName: csvFileNameForSession(sessionName),
    mimeType: 'text/csv',
  );
}

/// Build the session's CSV in the dynamite-csv v1 format, v1C framing
/// (csv-format-v1C.md): a `# dynamite-csv 1` magic line, a one-line
/// metadata JSON carrying everything needed to reproduce the converted
/// columns (frozen recording-time calibration, tares, sample rate, ssn
/// origin, device identity + board-cal provenance), the same object
/// re-rendered as glanceable YAML comment lines, then the grid of raw +
/// converted columns (`ssn, ch0..chN-1, ch0_<unit>..chN-1_<unit>`).
///
/// [unit] is the file's single converted unit (quartet 2), chosen by the
/// user in the export flow; a channel that can't reach it (a force unit
/// with no load cell assigned) gets an all-blank column. Dropped (gap)
/// samples keep their `ssn` row with every sample cell blank. Values are
/// fixed-point with per-column precision ([DisplayUnit.exportDecimalsFor]);
/// conventions are `\n` endings, no BOM, dot decimals — see the spec.
///
/// [recordedAtIso] is the session row's frozen `recorded_at` string (the
/// local wall clock with offset); `recorded_unix` is derived from it here,
/// so the two fields can never disagree. [deviceInfo] is the session
/// row's frozen device-identity block (see [toSessionDeviceMetadata]).
///
/// TODO(perf): the whole CSV is built in memory as one string — the format
/// milestone will replace this with a chunked writer (see
/// SessionStore.loadSession's own materialization note).
String buildSessionCsv(
  SessionData data,
  DisplayUnit unit, {
  required String recordedAtIso,
  required String generator,
  required Map<String, Object?> deviceInfo,

  /// The recording never completed (no finalize endorsement): every byte
  /// in the file is valid, but the tail may be missing. Emitted as the
  /// additive metadata key `interrupted` (unknown-key tolerant per
  /// csv-format-v1.md) — the file states its own provenance.
  bool interrupted = false,
}) {
  final int n = data.channels.length;
  // The writer recorded the true device counter at the session's first
  // sample when the row was created.
  final int ssnOrigin = data.ssnOrigin;

  // Per-channel quartet-2 cell formatters, computed once from the session's
  // frozen calibration; each closure folds in the column's fixed-point
  // precision. Null is a force unit on a cell-less channel — an all-blank
  // column (the file's '—').
  final formatters = [
    for (int ch = 0; ch < n; ch++)
      _columnFormatter(unit, data.converterFor(ch)),
  ];

  final metadata = _metadata(
    data,
    unit,
    ssnOrigin,
    recordedAtIso,
    generator,
    deviceInfo,
    n,
    interrupted,
  );
  final buf = StringBuffer()
    ..writeln('# dynamite-csv 1')
    ..writeln('# ${jsonEncode(metadata)}');
  // The human-glanceable rendering of the same object (csv-format-v1C.md
  // §The two renderings): line 2 stays the only machine form.
  for (final line in yamlLinesForCsvMetadata(metadata)) {
    buf.writeln('# $line');
  }

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
  ChannelConverter conv,
) {
  final convert = conv.netMap(unit);
  final decimals = unit.exportDecimalsFor(conv);
  if (convert == null || decimals == null) return null;
  return (raw) => convert(raw.toDouble()).toStringAsFixed(decimals);
}

/// The metadata line's JSON object (csv-format-v1C.md §Metadata schema):
/// one compact object, all top-level fields required in v1, nullable
/// subfields emitted as null. Map order here is the emission order (and
/// matches the spec).
Map<String, Object?> _metadata(
  SessionData data,
  DisplayUnit unit,
  int ssnOrigin,
  String recordedAtIso,
  String generator,
  Map<String, Object?> device,
  int n,
  bool interrupted,
) {
  return {
    'format': 'dynamite-csv',
    'version': 1,
    'generator': generator,
    // The human-glanceable timestamp; machines use recorded_unix, which is
    // derived from the stored string here so the two cannot disagree.
    'recorded_at': recordedAtIso,
    'recorded_unix':
        DateTime.parse(recordedAtIso).millisecondsSinceEpoch ~/ 1000,
    'sample_rate_hz': data.sampleRate,
    'ssn_origin': ssnOrigin,
    'converted_unit': unit.csvSymbol,
    // Absent when false: the complete-session shape stays exactly the v1
    // schema, and readers tolerate the key appearing (additive change).
    if (interrupted) 'interrupted': true,
    // The recording apparatus (frozen at recording start): identity from
    // the session row's deviceInfo (nulls for a session without
    // identity — web-recorded serial, unreadable DIS), the electrical
    // configuration in effect, and the board calibration's provenance.
    // Both afe and cal are descriptive traceability; the operative
    // transfer function is each channel's board_cal.
    'device': {
      ...device,
      'afe': {
        'adc_ref_v': data.calibrationFor(0).board.nominals?.adcFsrV,
        'front_end_gain': data.calibrationFor(0).board.nominals?.afeGain,
        'adc_gain': [
          for (int ch = 0; ch < n; ch++)
            data.calibrationFor(ch).board.nominals?.pgaGain,
        ],
        // The excitation the mV columns are scaled by (the mV anchor):
        // nominal until flash carries a characterized value — reproducing
        // an mV column outside the app needs exactly this number, and it
        // lives nowhere else in the file for a session without board_cal.
        'excitation_v': data.calibrationFor(0).board.displayExcitationV,
      },
      // Board-cal provenance (SessionBoardMeta.toJson): the cal.* document,
      // the board-state verdicts (cal_data_invalid, constants status), and
      // the per-constant provenance tags. Null for a session recorded with
      // no board data resolved.
      'cal': data.boardMeta?.toJson(),
    },
    'channels': [
      for (int ch = 0; ch < n; ch++)
        _channelMetadata(data.calibrationFor(ch), data.tares[ch]),
    ],
  };
}

/// The canonical YAML rendering of the metadata object (csv-format-v1C.md
/// §The two renderings): a deterministic function of the JSON object's
/// emission order and values — derived documentation, re-derivable from
/// line 2 by a validator without parsing YAML. The closed schema (maps,
/// strings, numbers, booleans, null, scalar flow sequences, sequences of
/// mappings) is a complete emitter; anything outside it throws.
List<String> yamlLinesForCsvMetadata(Map<String, Object?> metadata) => [
  for (final MapEntry(:key, :value) in metadata.entries)
    ..._yamlEntry(key, value, 0),
];

List<String> _yamlEntry(String key, Object? value, int indent) {
  final pad = ' ' * indent;
  if (value is Map) {
    if (value.isEmpty) return ['$pad$key: {}'];
    return [
      '$pad$key:',
      for (final MapEntry(:key, :value) in value.entries)
        ..._yamlEntry(key as String, value, indent + 2),
    ];
  }
  if (value is List) {
    if (value.isEmpty) return ['$pad$key: []'];
    if (value.every((e) => e is! Map)) {
      return ['$pad$key: [${value.map(_yamlScalar).join(', ')}]'];
    }
    return [
      '$pad$key:',
      for (final item in value)
        ..._yamlSequenceMapping(item as Map, indent + 2),
    ];
  }
  return ['$pad$key: ${_yamlScalar(value)}'];
}

/// One `- ` item of a mapping sequence: the indicator sits at the parent's
/// child indent, the first key rides its line, subsequent keys align under
/// it (children nest another two).
List<String> _yamlSequenceMapping(Map<dynamic, dynamic> mapping, int indent) {
  if (mapping.isEmpty) {
    throw ArgumentError('empty mapping in a YAML sequence');
  }
  final pad = ' ' * indent;
  final lines = <String>[];
  var first = true;
  for (final MapEntry(:key, :value) in mapping.entries) {
    final sub = _yamlEntry(key as String, value, indent + 2);
    if (first) {
      lines.add('$pad- ${sub.first.trimLeft()}');
      lines.addAll(sub.skip(1));
      first = false;
    } else {
      lines.addAll(sub);
    }
  }
  return lines;
}

/// Scalar rendering per the canonical rules: strings single-quoted with `'`
/// doubled; numbers exactly as JSON renders them (fixed-point); booleans and
/// null as the YAML 1.2 core-schema spellings.
String _yamlScalar(Object? value) {
  if (value == null) return 'null';
  if (value is String) return "'${value.replaceAll("'", "''")}'";
  if (value is bool) return '$value';
  if (value is num) return jsonEncode(value);
  throw ArgumentError('no canonical YAML form for ${value.runtimeType}');
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
