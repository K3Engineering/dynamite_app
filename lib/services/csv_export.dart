/// CSV export of a recorded session: building the dynamite-csv file
/// (docs/csv-format-v2.md) as a deliverable artifact. Handing the file to
/// the OS (save-as dialog, share sheet) is the caller's composition with
/// export_delivery.dart — this module never touches platform UI.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:yaml_writer/yaml_writer.dart';

import '../models/app_meta.dart';
import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';
import '../models/channel_converter.dart';
import '../models/display_unit.dart';
import 'export_names.dart';
import 'session_data.dart';
import 'session_metadata.dart';

/// The dynamite-csv file format's view of a display unit: the
/// header/metadata symbol and the per-column fixed-point precision. Kept here, not on the enum — the file format is
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

/// Build the session's CSV in the dynamite-csv format: a
/// `# dynamite-csv 1` magic line, a one-line
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
  /// additive metadata key `interrupted` (readers ignore unknown keys) —
  /// the file states its own provenance.
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
  // The human-glanceable rendering of the same object: line 2 stays the
  // only machine form.
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

/// The metadata line's JSON object: one compact object, all top-level
/// fields required, nullable subfields emitted as null. Map order here is
/// the emission order (and matches the spec).
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
        'adc_ref_v': data.calibrationFor(0).board?.nominals.adcFsrV,
        'front_end_gain': data.calibrationFor(0).board?.nominals.afeGain,
        'adc_gain': [
          for (int ch = 0; ch < n; ch++)
            data.calibrationFor(ch).board?.nominals.pgaGain,
        ],
        // The excitation the mV columns are scaled by (the mV anchor):
        // nominal until flash carries a characterized value — reproducing
        // an mV column outside the app needs exactly this number, and it
        // lives nowhere else in the file for a session without board_cal.
        'excitation_v': data.calibrationFor(0).board?.displayExcitationV,
      },
      // Raw store provenance frozen at recording start; descriptive only —
      // the operative transfer function remains channels[].board_cal.
      // Null for sessions recorded before this field existed.
      'kvs': data.deviceKvs?.toJson(),
    },
    'channels': [
      for (int ch = 0; ch < n; ch++)
        _channelMetadata(data.calibrationFor(ch), data.tares[ch]),
    ],
  };
}

/// The YAML writer for the metadata block. Rendering (quoting, indentation,
/// number and string style) is the library's: the block is
/// implementation-defined derived documentation (csv-format-v2.md §The two
/// renderings), re-derivable from line 2, and nothing parses it back as a
/// contract. [toEncodable] rejects anything outside the JSON-shaped schema
/// the metadata is built from, so a stray platform object fails the export
/// instead of emitting garbage.
final YamlWriter _yamlWriter = YamlWriter(
  toEncodable: (object) =>
      throw ArgumentError('no YAML form for ${object.runtimeType}'),
);

/// The YAML rendering of the metadata object, as comment-block lines.
List<String> yamlLinesForCsvMetadata(Map<String, Object?> metadata) =>
    const LineSplitter().convert(_yamlWriter.write(metadata));

/// One `channels[]` entry: the assigned load cell (null = none), the
/// recording-time tare in raw counts (null = the channel recorded gross),
/// and the factory board cal — null when the channel is uncalibrated, i.e.
/// converted values are nominal-referred. Calibration is board-uniform (all
/// channels calibrated or none — see [BoardCalibration.fromKv]).
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
    'board_cal': board is CalibratedChannelBoard ? board.toJson() : null,
  };
}

/// The CSV filename for a session: the session name sanitized per
/// [exportFileNameFor].
String csvFileNameForSession(String sessionName) =>
    exportFileNameFor(sessionName, 'csv', fallback: 'session');
