/// Per-session metadata journal: append-only, newline-terminated JSON objects.
/// Line 1 is the session's identity (written once, at the first data packet);
/// every later line is a whole snapshot of the mutable display state, and the
/// LAST complete one wins.
///
/// Reads are tail-safe: a line without its terminating newline is never parsed,
/// so a crash tear drops the final line. A complete line that fails to parse is
/// corruption and throws.
///
/// Line 1 schema (`version` bumps on breaking changes; readers ignore unknown
/// keys):
/// ```json
/// {"version":1,"name":"...","sampleRate":1000,"channelCount":4,
///  "channelLabels":["Ch 1",...],"tares":[null,123.5,...],
///  "calibration":[{...},...],"displayUnit":"kgf","deviceInfo":{...},
///  "deviceKvs":{"factory":{...},"user":{...}} | null,
///  "recordedAt":"2026-08-28T14:30:12.345+02:00",
///  "ssnOrigin":123456,"visibleChannels":[true,...]}
/// ```
/// Edit-line schema (a snapshot, all three fields required, never a delta):
/// ```json
/// {"name":"...","notes":"...","visibleChannels":[true,...]}
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../models/channel_calibration.dart';
import '../models/device_flash.dart';
import '../models/display_unit.dart';

const int sessionJournalVersion = 1;

/// Line 1 of the journal: the session header, frozen at recording start, so
/// later recalibration or re-taring can't rewrite history.
@immutable
class SessionMeta {
  const new({
    required this.name,
    required this.sampleRate,
    required this.channelCount,
    required this.channelLabels,
    required this.tares,
    required this.calibration,
    required this.displayUnit,
    required this.deviceInfo,
    this.deviceKvs,
    required this.recordedAt,
    required this.ssnOrigin,
    required this.visibleChannels,
  });

  final String name;
  final int sampleRate;
  final int channelCount;
  final List<String> channelLabels;

  /// Per-channel tare offsets in counts; null = that channel was untared.
  final List<double?> tares;

  /// Per-channel calibration at recording time (exactly [channelCount]
  /// entries).
  final List<ChannelCalibration> calibration;

  /// The CSV export's default converted unit.
  final DisplayUnit displayUnit;

  /// The device identity at recording start (the CSV `device` block).
  final Map<String, Object?> deviceInfo;

  /// The raw device KVS at recording start. Null on older sessions.
  final KvsSnapshot? deviceKvs;

  /// Local wall clock at recording start with its zone offset (the CSV
  /// `recorded_at`).
  final String recordedAt;

  /// Device sample-counter value at the session's first sample (the CSV
  /// `ssn_origin`).
  final int ssnOrigin;

  /// Initial per-session channel visibility; post-recording edits ride in
  /// [SessionEdit].
  final List<bool> visibleChannels;

  Map<String, dynamic> toJson() => {
    'version': sessionJournalVersion,
    'name': name,
    'sampleRate': sampleRate,
    'channelCount': channelCount,
    'channelLabels': channelLabels,
    'tares': tares,
    'calibration': [for (final c in calibration) c.toJson()],
    'displayUnit': displayUnit.name,
    'deviceInfo': deviceInfo,
    'deviceKvs': ?deviceKvs?.toJson(),
    'recordedAt': recordedAt,
    'ssnOrigin': ssnOrigin,
    'visibleChannels': visibleChannels,
  };

  /// Strict inverse of [toJson]: wrong types, wrong list lengths against
  /// [channelCount], or a wrong version throw [FormatException]. Unknown keys
  /// are ignored (additive schema changes), a wrong version is not.
  factory fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! int || version != sessionJournalVersion) {
      throw FormatException('journal header: bad version: $version');
    }

    /// A required [key] present as a T, else [FormatException]. (The `bad`
    /// message template is the same for every field, so it lives here.)
    T req<T>(String key) {
      final v = json[key];
      if (v is! T) throw FormatException('journal header: bad $key: $v');
      return v;
    }

    /// A required positive int [key].
    int reqPositive(String key) {
      final v = req<int>(key);
      if (v <= 0) throw FormatException('journal header: bad $key: $v');
      return v;
    }

    final name = req<String>('name');
    final sampleRate = reqPositive('sampleRate');
    final channelCount = reqPositive('channelCount');

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

    final displayUnitName = req<String>('displayUnit');
    // Must be a unit this build can name: an unrecognized string parse-
    // accepted here would later fall back to a default unit — a silent
    // rewrite of frozen provenance. Damaged is the verdict.
    final DisplayUnit displayUnit;
    try {
      displayUnit = DisplayUnit.values.byName(displayUnitName);
      // byName's ArgumentError is malformed DATA here (a unit string this
      // build can't name), not a programming bug — translated to the parse
      // verdict below.
      // ignore: avoid_catching_errors
    } on ArgumentError {
      throw FormatException(
        'journal header: bad displayUnit: $displayUnitName',
      );
    }
    // Typed by key, not just by value: [Map.unmodifiableOf] copies with a
    // checked cast, so a non-string key would otherwise surface as a
    // TypeError here instead of the damaged-session verdict callers catch.
    final deviceInfo = req<Map<String, Object?>>('deviceInfo');
    final deviceKvsJson = json['deviceKvs'];
    final deviceKvs = deviceKvsJson == null
        ? null
        : KvsSnapshot.fromJson(
            deviceKvsJson is Map
                ? Map<String, dynamic>.from(deviceKvsJson)
                : throw const FormatException(
                    'journal header: deviceKvs must be an object or null',
                  ),
          );
    final recordedAt = req<String>('recordedAt');
    // The CSV export hands this string out as the recording's timestamp, so it
    // must actually parse as ISO 8601; anything else would export garbage
    // under a real session's name.
    if (DateTime.tryParse(recordedAt) == null) {
      throw FormatException('journal header: bad recordedAt: $recordedAt');
    }
    final ssnOrigin = req<int>('ssnOrigin');

    return SessionMeta(
      name: name,
      sampleRate: sampleRate,
      channelCount: channelCount,
      channelLabels: List.unmodifiableOf(channelLabels),
      tares: List.unmodifiableOf(tares),
      calibration: List.unmodifiableOf(calibration),
      displayUnit: displayUnit,
      deviceInfo: Map.unmodifiableOf(deviceInfo),
      deviceKvs: deviceKvs,
      recordedAt: recordedAt,
      ssnOrigin: ssnOrigin,
      visibleChannels: List.unmodifiableOf(visibleChannels),
    );
  }
}

/// A whole snapshot of the mutable display state, appended by a post-recording
/// edit; the last complete one wins.
@immutable
class SessionEdit {
  const new({
    required this.name,
    required this.notes,
    required this.visibleChannels,
  });

  final String name;
  final String notes;
  final List<bool> visibleChannels;

  /// The state to show when no edit line survives: the meta's recording-time
  /// values, with empty notes.
  factory initial(SessionMeta meta) => SessionEdit(
    name: meta.name,
    notes: '',
    visibleChannels: meta.visibleChannels,
  );

  SessionEdit copyWith({
    String? name,
    String? notes,
    List<bool>? visibleChannels,
  }) => SessionEdit(
    name: name ?? this.name,
    notes: notes ?? this.notes,
    visibleChannels: visibleChannels ?? this.visibleChannels,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'notes': notes,
    'visibleChannels': visibleChannels,
  };

  /// Strict against [channelCount]: a different channel layout is not an edit
  /// of this session. Unknown keys are ignored.
  factory fromJson(Map<String, dynamic> json, int channelCount) {
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
      visibleChannels: List.unmodifiableOf([
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
@immutable
class SessionJournal {
  const new _({
    required this.meta,
    required this.edit,
    required this.completeBytes,
  });

  /// Line 1, strictly validated.
  final SessionMeta meta;

  /// The last complete edit line, or null when none survived.
  final SessionEdit? edit;

  /// The state to display: [edit] when present, else the meta's
  /// recording-time values with empty notes.
  SessionEdit get effectiveEdit => edit ?? SessionEdit.initial(meta);

  /// Byte offset just past the last complete line; everything after is a torn
  /// tail. The write path truncates the file here before appending an edit, so
  /// a new line never lands behind unreadable bytes.
  final int completeBytes;
}

/// Encode [meta] as the journal's line 1 (newline-terminated) bytes.
Uint8List encodeSessionMeta(SessionMeta meta) =>
    utf8.encode('${jsonEncode(meta.toJson())}\n');

/// Encode [edit] as a journal append line (newline-terminated) bytes.
Uint8List encodeSessionEdit(SessionEdit edit) =>
    utf8.encode('${jsonEncode(edit.toJson())}\n');

/// Parse the journal bytes. Line 1 and every complete later line must parse —
/// anything else throws [FormatException] (the caller's damaged verdict). Only
/// an unterminated trailing fragment is a legitimate crash tear and is dropped.
@useResult
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
      // Line 1 is the session's identity; any failure is the damaged verdict.
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
