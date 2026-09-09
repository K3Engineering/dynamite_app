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
/// key. The typed parse consumes each folder separately (Factory → board
/// half, User → slots) — there is no cross-folder merge. Raw values are
/// also session provenance (the CSV's `device.kvs`) — conversions never
/// consult them.
class KvsSnapshot {
  KvsSnapshot({
    required Map<String, String> factory,
    required Map<String, String> user,
  }) : factory = Map.unmodifiable(SplayTreeMap.of(factory)),
       user = Map.unmodifiable(SplayTreeMap.of(user)) {
    // Flash content must be representable in the export journal's canonical
    // YAML — the single-quoted scalar form can't hold control characters.
    // Catching them here keeps an exotic byte out of the app's state, not
    // out of exports weeks later: they can only come from wire/firmware
    // corruption (values the app writes are normalized at toKv).
    for (final MapEntry(:key, :value) in [
      ...factory.entries,
      ...user.entries,
    ]) {
      if (key.contains(_controlChars) || value.contains(_controlChars)) {
        throw FormatException('KVS snapshot: control character in "$key"');
      }
    }
  }

  static final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F]');

  /// Parse the legacy single-text flash form, routing the exact slot keys
  /// to User and every other key to Factory, mirroring the firmware layout.
  /// Used by fixtures (the demo device, test docs) — the wire form is the
  /// folder-separated KVS itself.
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

  /// Parse the legacy single-text flash form (fixtures — see
  /// [KvsSnapshot.fromFlashDoc]). Throws like [fromKvs].
  factory DeviceFlash.parse(String text, {required List<double> pgaGains}) =>
      DeviceFlash.fromKvs(KvsSnapshot.fromFlashDoc(text), pgaGains: pgaGains);

  /// Parse the typed board/slot halves out of a raw KVS snapshot. Each half
  /// reads its own folder: the board half ([BoardCalibration.fromKv]) is
  /// strict (Factory can have no write in flight — partial or malformed data
  /// is corrupt flash); the slot half ([RigSlots.fromKv]) is lenient (the
  /// app owns those keys: an unparseable slot reads as empty, the raw value
  /// stays visible in [kvs], and the next save reconciles the device).
  /// [pgaGains] is the ADC's GAIN-register readback for board-constant
  /// resolution — always present: an unreadable ADC config fails the
  /// connection upstream (see `BleLinkManager`).
  factory DeviceFlash.fromKvs(
    KvsSnapshot kvs, {
    required List<double> pgaGains,
  }) => DeviceFlash(
    board: BoardCalibration.fromKv(kvs.factory, pgaGains: pgaGains),
    slots: RigSlots.fromKv(kvs.user),
    kvs: kvs,
  );
}
