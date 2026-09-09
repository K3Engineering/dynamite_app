import 'dart:collection';

import 'board_calibration.dart';
import 'load_cell.dart';

// ---------------------------------------------------------------------------
// The device flash document: the factory board calibration (read-only to
// the app) plus the app-writable load cell slots, as the one `key=value`
// document the device's KVS holds. The per-channel join of the two halves
// ([ChannelCalibration]) that the unit layer consumes lives in
// channel_calibration.dart; the line parser itself ([parseFlashKv]) lives
// with the board file, the document's original content.
//
// The app OWNS the schema slot keys and only those: a save SETs/DELs the
// exact `lcN.*` keys in the User namespace and never touches the board half
// or any unknown key — see `KvsFlashTransport.writeSlots`.
// ---------------------------------------------------------------------------

/// The device KVS as read: folder-separated raw key/value pairs, sorted by
/// key. This is provenance only — conversions never consult it.
class KvsSnapshot {
  KvsSnapshot({
    required Map<String, String> factory,
    required Map<String, String> user,
  }) : factory = Map.unmodifiable(SplayTreeMap.of(factory)),
       user = Map.unmodifiable(SplayTreeMap.of(user));

  /// A test/document convenience: routes the exact slot keys to User and
  /// every other key to Factory, mirroring the firmware layout.
  factory KvsSnapshot.fromFlashDoc(String text) {
    final factory = <String, String>{};
    final user = <String, String>{};
    for (final e in parseFlashKv(text).entries) {
      (rigSlotKeys.contains(e.key) ? user : factory)[e.key] = e.value;
    }
    return KvsSnapshot(factory: factory, user: user);
  }

  final Map<String, String> factory;
  final Map<String, String> user;

  /// The merged key/value view used by the typed parse: Factory first, with
  /// a User duplicate shadowing the Factory copy.
  Map<String, String> get merged => {...factory, ...user};

  /// The flash document text form for callers that still need text.
  String toFlashDoc() =>
      [for (final e in merged.entries) '${e.key}=${e.value}'].join('\n');

  /// Apply a complete slot-key save to the User folder.
  KvsSnapshot withUserSlots(Map<String, String> lcKeys) {
    final updated = Map<String, String>.of(user)
      ..removeWhere((key, _) => rigSlotKeys.contains(key))
      ..addAll(lcKeys);
    return KvsSnapshot(factory: factory, user: updated);
  }

  Map<String, Object?> toJson() => {'factory': factory, 'user': user};

  /// Strict inverse of [toJson]: every entry must be a string key/value.
  factory KvsSnapshot.fromJson(Map<String, dynamic> json) {
    Map<String, String> folder(String name) {
      final value = json[name];
      if (value is! Map) {
        throw FormatException('KVS snapshot: bad $name folder');
      }
      final out = <String, String>{};
      for (final e in value.entries) {
        final key = e.key;
        final v = e.value;
        if (key is! String || v is! String) {
          throw FormatException('KVS snapshot: bad $name entry');
        }
        out[key] = v;
      }
      return out;
    }

    return KvsSnapshot(factory: folder('factory'), user: folder('user'));
  }
}

/// The device flash document: the factory board calibration (read-only to
/// the app) plus the app-writable load cell slots.
class DeviceFlash {
  DeviceFlash({required this.board, required this.slots, required this.kvs});

  final BoardCalibration board;
  final RigSlots slots;

  /// The raw store the typed halves were parsed from (session provenance).
  final KvsSnapshot kvs;

  /// Parse a whole flash document.
  /// [pgaGains] is the ADC's GAIN-register readback for board-constant
  /// resolution — always present: an unreadable ADC config fails the
  /// connection upstream (see `BleLinkManager`).
  ///
  /// Throws [FormatException] on present-but-invalid known content (see
  /// [BoardCalibration.fromKv] and [RigSlots.fromKv]): a document the app
  /// can't fully make sense of parks the connection for recovery rather
  /// than degrading into an instrument that hides corruption — and into a
  /// save that would delete the corrupt-but-recoverable keys. An EMPTY
  /// document is legal (an unprovisioned unit). Unknown keys are ignored:
  /// they are not the app's data, and the app's writes never touch them.
  factory DeviceFlash.parse(String text, {required List<double> pgaGains}) =>
      DeviceFlash.fromKvs(KvsSnapshot.fromFlashDoc(text), pgaGains: pgaGains);

  /// Parse the typed board/slot halves out of a raw KVS snapshot.
  factory DeviceFlash.fromKvs(
    KvsSnapshot kvs, {
    required List<double> pgaGains,
  }) {
    final kv = kvs.merged;
    return DeviceFlash(
      board: BoardCalibration.fromKv(kv, pgaGains: pgaGains),
      slots: RigSlots.fromKv(kv),
      kvs: kvs,
    );
  }
}
