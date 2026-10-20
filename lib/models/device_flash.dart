import 'dart:collection';

import 'package:meta/meta.dart';

import 'board_calibration.dart';
import 'load_cell.dart';

// ---------------------------------------------------------------------------
// The device flash document: the board calibration (the Factory group, or
// the User recalibration overriding it) plus the app-writable load cell
// slots, as the folder-separated KVS store the device holds. The per-channel
// join of the two halves ([ChannelCalibration]) that the unit layer consumes
// lives in channel_calibration.dart.
//
// The app OWNS the schema slot keys and only those: a save SETs/DELs the
// exact `lcN.*` keys in the User namespace and never touches the board half
// or any unknown key — see `KvsFlashTransport.writeSlots`. Reverting a User
// calibration is a separate explicit action that DELs the User cal-group keys
// and nothing else.
// ---------------------------------------------------------------------------

/// The device KVS as read: folder-separated raw key/value pairs, sorted by
/// key. The typed parse reads the calibration group from User first, then
/// Factory (a recalibration overrides the as-built one), and the slots from
/// User. Raw values are also session provenance (the CSV's `device.kvs`) —
/// conversions never consult them.
@immutable
class KvsSnapshot {
  KvsSnapshot({
    required Map<String, String> factory,
    required Map<String, String> user,
  }) : factory = Map.unmodifiable(SplayTreeMap.of(factory)),
       user = Map.unmodifiable(SplayTreeMap.of(user));

  final Map<String, String> factory;
  final Map<String, String> user;

  /// Apply a complete slot-key save to the User folder.
  @useResult
  KvsSnapshot withUserSlots(Map<String, String> lcKeys) {
    final updated = Map<String, String>.of(user)
      ..removeWhere((key, _) => rigSlotKeys.contains(key))
      ..addAll(lcKeys);
    return KvsSnapshot(factory: factory, user: updated);
  }

  /// Drop the User-folder calibration group (a revert to factory). Throws
  /// when the User folder holds no cal-group keys — nothing to revert.
  @useResult
  KvsSnapshot withoutUserCalGroup() {
    if (!user.keys.any(calGroupKeys.contains)) {
      throw StateError('no User calibration to revert');
    }
    final updated = Map<String, String>.of(user)
      ..removeWhere((key, _) => calGroupKeys.contains(key));
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
@immutable
class DeviceFlash {
  const DeviceFlash({
    required this.board,
    required this.slots,
    required this.kvs,
  });

  final BoardCalibration board;
  final RigSlots slots;

  /// The raw store the typed halves were parsed from (session provenance).
  final KvsSnapshot kvs;

  /// Parse the typed board/slot halves out of a raw KVS snapshot. The board
  /// half ([BoardCalibration.fromKv]) is strict — its [FormatException] is
  /// caught here and becomes an [InvalidBoardCalibration], a board that
  /// streams raw counts with a warning instead of failing the connection. A
  /// torn User recalibration lands here: raw counts until the user reverts.
  /// The slot half ([RigSlots.fromKv]) is lenient (the app owns those keys: an
  /// unparseable slot reads as empty, the raw value stays visible in [kvs],
  /// and the next save reconciles the device). [pgaGains] is the ADC's
  /// GAIN-register readback for board-constant resolution — always present: an
  /// unreadable ADC config fails the connection upstream (see
  /// `BleLinkManager`).
  factory DeviceFlash.fromKvs(
    KvsSnapshot kvs, {
    required List<double> pgaGains,
  }) {
    final BoardCalibration board;
    try {
      board = BoardCalibration.fromKv(
        kvs.factory,
        user: kvs.user,
        pgaGains: pgaGains,
      );
    } on FormatException catch (e) {
      return DeviceFlash(
        board: InvalidBoardCalibration(e.message),
        slots: RigSlots.fromKv(kvs.user),
        kvs: kvs,
      );
    }
    return DeviceFlash(
      board: board,
      slots: RigSlots.fromKv(kvs.user),
      kvs: kvs,
    );
  }
}
