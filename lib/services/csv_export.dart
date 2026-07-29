/// CSV export of a recorded session, plus the save/share plumbing that hands
/// the generated file to the OS.
///
/// Two delivery paths, two plugins (no single package does both well):
/// - [downloadSessionCsv] — file_picker's `saveFile`: a save-as dialog on
///   Android/iOS/macOS/Windows/Linux, a browser download on web.
/// - [shareSessionCsv] — share_plus's share sheet ("Save to Files" on iOS,
///   the Web Share API with download fallback on web). File sharing is
///   unsupported on Linux — see [csvShareSupportedHere].
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
import 'package:share_plus/share_plus.dart';

import '../models/display_unit.dart';
import 'csv_export_temp_stub.dart'
    if (dart.library.io) 'csv_export_temp_io.dart';
import 'database.dart';
import 'session_storage.dart';

/// Whether [shareSessionCsv] can present a share UI on this platform:
/// share_plus shares files on Android, iOS, macOS, Windows and web, but not
/// Linux.
bool get csvShareSupportedHere {
  if (kIsWeb) return true;
  return defaultTargetPlatform != TargetPlatform.linux &&
      defaultTargetPlatform != TargetPlatform.fuchsia;
}

/// Download [session]'s recorded [data] as CSV: a save-as dialog on native
/// platforms, a browser download on web.
///
/// Returns a user-facing result message, or null when the user cancelled —
/// callers should stay silent then. Errors are thrown for the caller to
/// surface. Note the whole file crosses the platform channel as in-memory
/// bytes (file_picker's only API); a chunked writer is planned with the
/// format milestone.
Future<String?> downloadSessionCsv({
  required Session session,
  required SessionData data,
}) async {
  final (bytes, fileName) = _prepareCsv(session, data);
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
  Rect? sharePositionOrigin,
}) async {
  final (bytes, fileName) = _prepareCsv(session, data);
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
    // The user backed out of the share sheet.
    ShareResultStatus.dismissed => null,
    // The platform can't tell what happened; treat as shared.
    ShareResultStatus.unavailable => 'Shared $fileName (status unknown)',
  };
}

/// Build the CSV bytes and filename for [session]'s [data]. Shared by both
/// delivery paths.
(Uint8List, String) _prepareCsv(Session session, SessionData data) {
  final labels = parseJsonColumn(
    session.channelLabels,
    data.channels.length,
    convert: (e) => e.toString(),
    fallback: (i) => 'Ch ${i + 1}',
  );
  final csv = buildSessionCsv(data, labels);
  return (
    Uint8List.fromList(utf8.encode(csv)),
    csvFileNameForSession(session.name),
  );
}

/// Build the session's CSV: a `time_s` column plus `<label>_raw` /
/// `<label>_kgf` column pairs per channel. Raw values are absolute ADC
/// counts; kgf is net of the session tare via the calibration recorded with
/// the session, blank when the channel had no load cell assigned. Dropped
/// (gap) samples get blank cells rather than the buffer's held values.
///
/// TODO(perf): the whole CSV is built in memory as one string — the format
/// milestone will replace this with a chunked writer (see
/// SessionStorage.loadSession's own materialization note).
String buildSessionCsv(SessionData data, List<String> labels) {
  final buf = StringBuffer();
  buf.write('time_s');
  for (int ch = 0; ch < data.channels.length; ch++) {
    final label = _csvCell(labels[ch]);
    buf.write(',${label}_raw,${label}_kgf');
  }
  buf.writeln();

  for (int s = 0; s < data.sampleCount; s++) {
    buf.write((s / data.sampleRate).toStringAsFixed(4));
    if (data.gaps.contains(s)) {
      // Dropped sample: the buffer holds a fabricated (held) value, so emit
      // blank cells rather than fake data.
      for (int ch = 0; ch < data.channels.length; ch++) {
        buf.write(',,');
      }
    } else {
      for (int ch = 0; ch < data.channels.length; ch++) {
        final raw = data.channels[ch][s];
        // kgf via the calibration recorded with the session; blank when
        // the channel had no load cell assigned.
        final kgf = DisplayUnit.kgf
            .converterFor(data.calibrationFor(ch), data.tares[ch])
            ?.call(raw.toDouble());
        buf.write(kgf == null ? ',$raw,' : ',$raw,${kgf.toStringAsFixed(6)}');
      }
    }
    buf.writeln();
  }
  return buf.toString();
}

/// The CSV filename for a session: the session name with characters that are
/// illegal in Windows/macOS/Android filenames replaced (auto session names
/// contain `:` — e.g. `2026-07-29 14:05:32`), leading dots stripped (they
/// would hide the file on macOS/Linux), trailing dots/spaces trimmed
/// (illegal on Windows), and a Windows reserved device name disambiguated
/// with an underscore — Windows refuses CON, NUL, COM1–COM9, LPT1–LPT9 and
/// friends regardless of extension, so the save dialog would reject the
/// suggested name outright.
String csvFileNameForSession(String sessionName) {
  final base = sessionName.isEmpty ? 'session' : sessionName;
  var name = base
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
      .replaceAll(RegExp(r'^\.+'), '')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = 'session';
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
  return '$name.csv';
}

/// Escape a CSV header cell that contains separators, quotes or newlines.
String _csvCell(String s) =>
    s.contains(RegExp(r'[,"\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
