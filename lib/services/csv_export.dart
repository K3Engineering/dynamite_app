/// CSV export of a recorded session, plus the save/share plumbing that hands
/// the generated file to the OS.
///
/// Two delivery paths, two plugins (no single package does both well):
/// - [downloadSessionCsv] — file_picker's `saveFile`: a save-as dialog on
///   Android/iOS/macOS/Windows/Linux, a browser download on web.
/// - [shareSessionCsv] — share_plus's share sheet ("Save to Files" on iOS,
///   the Web Share API with download fallback on web). File sharing is
///   unsupported on Linux — see [fileShareSupportedHere].
///
/// `file_selector` was dropped for this: its `getSaveLocation` is
/// unimplemented on Android and iOS (throws `UnimplementedError`), which is
/// what broke the previous export on mobile. (Verified against plugin
/// sources, July 2026.)
library;

import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../models/calibration.dart';
import '../models/device_info.dart';
import '../models/display_unit.dart';
import 'csv_export_temp_stub.dart'
    if (dart.library.io) 'csv_export_temp_io.dart';
import 'database.dart';
import 'session_storage.dart';

/// Whether the file-share flow ([shareSessionCsv], `shareCalibrationReport`)
/// can present a share UI on this platform: share_plus shares files on
/// Android, iOS, macOS, Windows and web, but not Linux.
bool get fileShareSupportedHere {
  if (kIsWeb) return true;
  return defaultTargetPlatform != TargetPlatform.linux &&
      defaultTargetPlatform != TargetPlatform.fuchsia;
}

/// Download [session]'s recorded [data] as CSV: a save-as dialog on native
/// platforms, a browser download on web. [unit] is the file's converted unit
/// (the user's pick in the export flow — see docs/csv-format-v1.md).
///
/// Returns a user-facing result message, or null when the user cancelled —
/// callers should stay silent then. Errors are thrown for the caller to
/// surface. Note the whole file crosses the platform channel as in-memory
/// bytes (file_picker's only API); a chunked writer is planned with the
/// format milestone.
Future<String?> downloadSessionCsv({
  required Session session,
  required SessionData data,
  required DisplayUnit unit,
}) async {
  final (bytes, fileName) = await _prepareCsv(session, data, unit);
  final savedTo = await FilePicker.saveFile(
    dialogTitle: 'Download session CSV',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['csv'],
    bytes: bytes,
  );
  if (kIsWeb) {
    // The browser handles the download; saveFile always returns null there.
    return 'Download started for $fileName';
  }
  // Null = user cancelled the dialog.
  return savedTo == null ? null : 'Saved to $savedTo';
}

/// Share [session]'s recorded [data] as CSV via the platform share sheet.
/// [unit] is the file's converted unit (see docs/csv-format-v1.md).
///
/// [sharePositionOrigin] anchors the iPad share popover; ignored elsewhere.
///
/// Returns a user-facing result message, or null when the user dismissed the
/// sheet. The share sheet doesn't say where the file went (or what the user
/// did with it), so the message can't either. Errors are thrown for the
/// caller to surface.
Future<String?> shareSessionCsv({
  required Session session,
  required SessionData data,
  required DisplayUnit unit,
  Rect? sharePositionOrigin,
}) async {
  final (bytes, fileName) = await _prepareCsv(session, data, unit);
  final XFile file;
  if (kIsWeb) {
    // XFile.name is ignored by most platforms; share_plus's fileNameOverrides
    // is what sets the shared/downloaded file's name.
    file = XFile.fromData(bytes, mimeType: 'text/csv');
  } else {
    file = XFile(await writeTempCsv(bytes, fileName), mimeType: 'text/csv');
  }
  ShareResult result;
  try {
    result = await SharePlus.instance.share(
      ShareParams(
        title: 'Share CSV',
        files: [file],
        fileNameOverrides: [fileName],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  } finally {
    if (!kIsWeb) await deleteTempCsv(file.path);
  }
  return switch (result.status) {
    ShareResultStatus.success => 'Shared $fileName',
    // Backed out of the share sheet: null = the caller shows no snackbar.
    ShareResultStatus.dismissed => null,
    // The platform can't tell what happened; treat as shared.
    ShareResultStatus.unavailable => 'Shared $fileName (status unknown)',
  };
}

/// App version for the metadata's `generator` field, fetched once (the
/// platform answer can't change during a run).
final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

/// Build the CSV bytes and filename for [session]'s [data] in [unit].
/// Shared by both delivery paths.
Future<(Uint8List, String)> _prepareCsv(
  Session session,
  SessionData data,
  DisplayUnit unit,
) async {
  final csv = buildSessionCsv(
    data,
    unit,
    recordedAt: session.createdAt,
    generator: 'dynamite-flutter ${(await _packageInfo).version}',
    deviceInfoJson: session.deviceInfoJson,
  );
  return (
    Uint8List.fromList(utf8.encode(csv)),
    csvFileNameForSession(session.name),
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
/// [DeviceInfo.toCsvDeviceMetadata]); null or malformed degrades to all-null
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
  // The writer persists the true device counter at row 0; null survives
  // only on sessions with no recorded packets (no data rows anyway).
  final int ssnOrigin = data.ssnOrigin ?? 0;
  final device = deviceInfoJson == null
      ? DeviceInfo.toCsvDeviceMetadata(name: null, info: null)
      : DeviceInfo.fromCsvDeviceMetadata(deviceInfoJson);

  // Per-channel quartet-2 cell formatters, computed once from the session's
  // frozen calibration; each closure folds in the column's fixed-point
  // precision. Null is a force unit on a cell-less channel — an all-blank
  // column (the file's '—').
  final formatters = [
    for (int ch = 0; ch < n; ch++)
      _columnFormatter(unit, data.calibrationFor(ch), data.tares[ch]),
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
  double tare,
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
/// recording-time tare in raw counts, and the factory board cal — null when
/// the channel is uncalibrated (the honesty marker: converted values are
/// nominal-referred; the piecewise map ignores the ladder resistors anyway).
Map<String, Object?> _channelMetadata(ChannelCalibration cal, double tareRaw) {
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

/// An export file name: [base] with characters that are illegal in
/// Windows/macOS/Android filenames replaced (auto session names contain `:`
/// — e.g. `2026-07-29 14:05:32`), leading dots stripped (they would hide the
/// file on macOS/Linux), trailing dots/spaces trimmed (illegal on Windows),
/// and a Windows reserved device name disambiguated with an underscore —
/// Windows refuses CON, NUL, COM1–COM9, LPT1–LPT9 and friends regardless of
/// extension, so the save dialog would reject the suggested name outright.
/// An empty (or scrubbed-away) base becomes [fallback].
String exportFileNameFor(
  String base,
  String extension, {
  String fallback = 'export',
}) {
  var name = (base.isEmpty ? fallback : base)
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
      .replaceAll(RegExp(r'^\.+'), '')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = fallback;
  // Reserved when followed by the end of the name or an extension dot
  // ("con.txt" is as refused as "con"); keep the name recognizable by
  // marking it right after the reserved word ("con_.txt").
  final reserved = RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?=\.|$)',
    caseSensitive: false,
  ).firstMatch(name);
  if (reserved != null) {
    name = '${reserved[0]}_${name.substring(reserved.end)}';
  }
  return '$name.$extension';
}
