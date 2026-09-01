/// The per-session metadata journal: an append-only file of newline-
/// terminated JSON objects. Line 1 is the session's identity (written once,
/// at the first data packet — name, calibration, tares, ssnOrigin live here
/// and nowhere else); every later line is a whole snapshot of the mutable
/// display state (post-recording rename/notes/visibleChannels), and the
/// LAST complete one wins.
///
/// Append-only means damage is tail-only: a crash mid-write leaves a torn
/// final line, which the reader drops by construction — a line without its
/// terminating newline is never parsed at all. A torn edit costs at most
/// that one edit; line 1 failing to parse makes the session
/// unreconstructable. A COMPLETE line that fails to parse is persisted
/// corruption, not a crash tear — the reader throws on it rather than
/// silently keeping the preceding state.
///
/// Line 1 schema (breaking changes bump `version`; additive changes add
/// keys, which readers ignore):
/// ```json
/// {"version":1,"name":"...","sampleRate":1000,"channelCount":4,
///  "channelLabels":["Ch 1",...],"tares":[null,123.5,...],
///  "calibration":[{...},...],"displayUnit":"kg","deviceInfo":{...},
///  "boardMeta":{...} | null,"recordedAt":"2026-08-28T14:30:12.345+02:00",
///  "ssnOrigin":123456,"visibleChannels":[true,...]}
/// ```
/// Edit-line schema (all three fields required — a snapshot, never a
/// delta, so there is no field-granularity merge):
/// ```json
/// {"name":"...","notes":"...","visibleChannels":[true,...]}
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';

const int sessionJournalVersion = 1;

/// Line 1 of the journal: the session header, frozen at recording start.
/// Playback converts through these snapshots, so later recalibration or
/// re-taring can never rewrite history.
class SessionMeta {
  const SessionMeta({
    required this.name,
    required this.sampleRate,
    required this.channelCount,
    required this.channelLabels,
    required this.tares,
    required this.calibration,
    required this.displayUnit,
    required this.deviceInfo,
    required this.boardMeta,
    required this.recordedAt,
    required this.ssnOrigin,
    required this.visibleChannels,
  });

  final String name;
  final int sampleRate;
  final int channelCount;
  final List<String> channelLabels;

  /// Per-channel tare offsets in counts, frozen at record start; null =
  /// that channel was recording gross (never tared).
  final List<double?> tares;

  /// Per-channel calibration in effect at recording time (must be exactly
  /// [channelCount] entries).
  final List<ChannelCalibration> calibration;

  /// The display unit at recording start (a `DisplayUnit.name`), frozen as
  /// the CSV export's default converted unit.
  final String displayUnit;

  /// The connected device's identity at recording start (the dynamite-csv
  /// `device` metadata block), frozen so export never consults live state.
  final Map<String, Object?> deviceInfo;

  /// Board-level calibration provenance at recording start; null when no
  /// board data resolved.
  final SessionBoardMeta? boardMeta;

  /// The local wall clock at recording start with its zone offset (the
  /// dynamite-csv `recorded_at`), stored verbatim — the offset is NOT
  /// derivable after the fact.
  final String recordedAt;

  /// Device sample-counter value at the session's first sample (the
  /// dynamite-csv `ssn_origin`).
  final int ssnOrigin;

  /// Initial per-session channel visibility: the live view's selection at
  /// recording time. Post-recording edits ride in [SessionEdit].
  final List<bool> visibleChannels;

  Map<String, dynamic> toJson() => {
    'version': sessionJournalVersion,
    'name': name,
    'sampleRate': sampleRate,
    'channelCount': channelCount,
    'channelLabels': channelLabels,
    'tares': tares,
    'calibration': [for (final c in calibration) c.toJson()],
    'displayUnit': displayUnit,
    'deviceInfo': deviceInfo,
    'boardMeta': ?boardMeta?.toJson(),
    'recordedAt': recordedAt,
    'ssnOrigin': ssnOrigin,
    'visibleChannels': visibleChannels,
  };

  /// Strict inverse of [toJson]: anything not exactly the schema above
  /// (wrong types, wrong list lengths against [channelCount], a version
  /// other than [sessionJournalVersion]) throws [FormatException] — the
  /// session is unreconstructable from anything less. Unknown keys are
  /// ignored (additive schema changes), a wrong version is not.
  factory SessionMeta.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! int || version != sessionJournalVersion) {
      throw FormatException('journal header: bad version: $version');
    }
    final name = json['name'];
    if (name is! String) {
      throw FormatException('journal header: bad name: $name');
    }
    final sampleRate = json['sampleRate'];
    if (sampleRate is! int || sampleRate <= 0) {
      throw FormatException('journal header: bad sampleRate: $sampleRate');
    }
    final channelCount = json['channelCount'];
    if (channelCount is! int || channelCount <= 0) {
      throw FormatException('journal header: bad channelCount: $channelCount');
    }

    List<T> list<T>(String key, T Function(Object? e) convert) {
      final v = json[key];
      if (v is! List || v.length != channelCount) {
        throw FormatException(
          'journal header: $key must be a list of $channelCount entries',
        );
      }
      return [for (final e in v) convert(e)];
    }

    final channelLabels = list<String>(
      'channelLabels',
      (e) => e is String
          ? e
          : throw const FormatException(
              'channelLabels entries must be strings',
            ),
    );
    final tares = list<double?>(
      'tares',
      (e) => e == null
          ? null
          : e is num && e.toDouble().isFinite
          ? e.toDouble()
          : throw const FormatException('tare entries must be numbers or null'),
    );
    final calibration = list<ChannelCalibration>(
      'calibration',
      (e) => ChannelCalibration.fromJson(
        e is Map
            ? Map<String, dynamic>.from(e)
            : throw const FormatException(
                'calibration entries must be objects',
              ),
      ),
    );
    final visibleChannels = list<bool>(
      'visibleChannels',
      (e) => e is bool
          ? e
          : throw const FormatException(
              'visibleChannels entries must be bools',
            ),
    );

    final displayUnit = json['displayUnit'];
    if (displayUnit is! String || displayUnit.isEmpty) {
      throw FormatException('journal header: bad displayUnit: $displayUnit');
    }
    final deviceInfo = json['deviceInfo'];
    if (deviceInfo is! Map) {
      throw FormatException('journal header: bad deviceInfo: $deviceInfo');
    }
    final boardMetaJson = json['boardMeta'];
    final boardMeta = boardMetaJson == null
        ? null
        : SessionBoardMeta.fromJson(
            boardMetaJson is Map
                ? Map<String, dynamic>.from(boardMetaJson)
                : throw const FormatException(
                    'journal header: boardMeta must be an object or null',
                  ),
          );
    final recordedAt = json['recordedAt'];
    if (recordedAt is! String || recordedAt.isEmpty) {
      throw FormatException('journal header: bad recordedAt: $recordedAt');
    }
    final ssnOrigin = json['ssnOrigin'];
    if (ssnOrigin is! int) {
      throw FormatException('journal header: bad ssnOrigin: $ssnOrigin');
    }

    return SessionMeta(
      name: name,
      sampleRate: sampleRate,
      channelCount: channelCount,
      channelLabels: List.unmodifiable(channelLabels),
      tares: List.unmodifiable(tares),
      calibration: List.unmodifiable(calibration),
      displayUnit: displayUnit,
      deviceInfo: Map.unmodifiable(deviceInfo),
      boardMeta: boardMeta,
      recordedAt: recordedAt,
      ssnOrigin: ssnOrigin,
      visibleChannels: List.unmodifiable(visibleChannels),
    );
  }
}

/// One whole snapshot of the mutable display state, as appended by a
/// post-recording user edit. The last complete edit line in the journal is
/// the state; line 1's [SessionMeta.name]/[SessionMeta.visibleChannels] are
/// the recording-time defaults when no edit line survives.
class SessionEdit {
  const SessionEdit({
    required this.name,
    required this.notes,
    required this.visibleChannels,
  });

  final String name;
  final String notes;
  final List<bool> visibleChannels;

  /// The state to display: this edit when present, else the meta's
  /// recording-time values with empty notes.
  factory SessionEdit.initial(SessionMeta meta) => SessionEdit(
    name: meta.name,
    notes: '',
    visibleChannels: meta.visibleChannels,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'notes': notes,
    'visibleChannels': visibleChannels,
  };

  /// Strict against [channelCount] (from line 1): a snapshot naming a
  /// different channel layout than the session's data is not an edit of
  /// THIS session. Unknown keys are ignored.
  factory SessionEdit.fromJson(Map<String, dynamic> json, int channelCount) {
    final name = json['name'];
    if (name is! String) {
      throw FormatException('journal edit: bad name: $name');
    }
    final notes = json['notes'];
    if (notes is! String) {
      throw FormatException('journal edit: bad notes: $notes');
    }
    final visible = json['visibleChannels'];
    if (visible is! List || visible.length != channelCount) {
      throw FormatException(
        'journal edit: visibleChannels must be a list of $channelCount bools',
      );
    }
    return SessionEdit(
      name: name,
      notes: notes,
      visibleChannels: List.unmodifiable([
        for (final e in visible)
          e is bool
              ? e
              : throw const FormatException(
                  'visibleChannels entries must be bools',
                ),
      ]),
    );
  }
}

/// The parsed content of a session journal.
class SessionJournal {
  const SessionJournal._({
    required this.meta,
    required this.edit,
    required this.completeBytes,
  });

  /// Line 1, strictly validated.
  final SessionMeta meta;

  /// The last complete edit line, or null when none survived (the torn
  /// tail takes at most the latest edit).
  final SessionEdit? edit;

  /// The state to display: [edit] when present, else the meta's
  /// recording-time values with empty notes.
  SessionEdit get effectiveEdit => edit ?? SessionEdit.initial(meta);

  /// Byte offset in the source just past the last complete, parseable
  /// line. Everything at/after it is a torn tail (possibly absent); the
  /// append discipline truncates the file here before writing a new edit
  /// line, so a new line never lands behind unreadable bytes.
  final int completeBytes;
}

/// Encode [meta] as the journal's line 1 (newline-terminated) bytes.
Uint8List encodeSessionMeta(SessionMeta meta) =>
    utf8.encode('${jsonEncode(meta.toJson())}\n');

/// Encode [edit] as a journal append line (newline-terminated) bytes.
Uint8List encodeSessionEdit(SessionEdit edit) =>
    utf8.encode('${jsonEncode(edit.toJson())}\n');

/// Parse the journal bytes. Line 1 must be present, newline-terminated and
/// strictly valid — anything else throws [FormatException] (the caller's
/// damaged-session verdict). So must every COMPLETE later line: a
/// newline-terminated line that fails to parse is persisted corruption
/// (the write path appends whole lines only), never a crash tear. Only an
/// unterminated trailing fragment is a legitimate tear and is dropped.
SessionJournal parseSessionJournal(Uint8List bytes) {
  var offset = 0;
  SessionMeta? meta;
  SessionEdit? edit;
  var completeBytes = 0;
  while (true) {
    final nl = _indexOfNewline(bytes, offset);
    if (nl < 0) break; // unterminated tail: torn or absent
    final lineBytes = Uint8List.sublistView(bytes, offset, nl);
    offset = nl + 1;
    if (meta == null) {
      // Line 1 is the session's identity: any failure here (bad UTF-8, bad
      // JSON, bad schema) propagates as the caller's damaged-session
      // verdict.
      meta = SessionMeta.fromJson(
        _object(utf8.decode(lineBytes), 'journal header'),
      );
    } else {
      edit = SessionEdit.fromJson(
        _object(utf8.decode(lineBytes), 'journal edit'),
        meta.channelCount,
      );
    }
    completeBytes = offset;
  }
  if (meta == null) {
    throw const FormatException('journal: no complete header line');
  }
  return SessionJournal._(meta: meta, edit: edit, completeBytes: completeBytes);
}

Map<String, dynamic> _object(String line, String what) {
  final decoded = jsonDecode(line);
  if (decoded is! Map) {
    throw FormatException('$what: line must be a JSON object');
  }
  return Map<String, dynamic>.from(decoded);
}

int _indexOfNewline(Uint8List bytes, int from) {
  for (int i = from; i < bytes.lengthInBytes; i++) {
    if (bytes[i] == 0x0A) return i;
  }
  return -1;
}
