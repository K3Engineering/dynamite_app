import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/board_calibration.dart';
import '../models/device_flash.dart';
import '../models/load_cell.dart';
import 'app_events.dart';
import 'link_backend.dart';

/// Owns the rig: the slot list read from the connected device, unsaved edits,
/// and the cross-device cell history. Unsaved edits die with a disconnect or
/// a replaced document; typed-in cell values survive in [history].
class RigState extends ChangeNotifier {
  /// [backend] yields the active link's device operations; [prefs] is injected
  /// so history loads synchronously in the constructor.
  RigState({
    required LinkBackend? Function() backend,
    required String Function() connectedDeviceName,
    required SharedPreferences prefs,
    required AppEvents events,
  }) : _backend = backend,
       _connectedDeviceName = connectedDeviceName,
       _prefs = prefs,
       _events = events {
    _loadHistory();
  }

  static const String _keyHistory = 'rig_history';

  /// History is a suggestion list, not an archive; least-recently-seen evicted.
  static const int historyCap = 50;

  final LinkBackend? Function() _backend;
  final String Function() _connectedDeviceName;
  final SharedPreferences _prefs;
  final AppEvents _events;

  /// The rig's document state (see [_DocState]).
  _DocState _doc = const _NoDoc();

  List<RigHistoryEntry> _history = [];

  // -- Reads -----------------------------------------------------------------

  /// Pending edits when dirty, else the device's flash state.
  RigSlots get effectiveSlots => switch (_doc) {
    _NoDoc() => RigSlots.empty(),
    _Clean(:final flash) => flash.slots,
    _Dirty(:final slots) => slots,
  };

  /// Cells converting the four channels (slots 0–3 of [effectiveSlots]).
  List<LoadCellProfile?> get channelCells => effectiveSlots.channelCells;

  /// Live-view row titles: cell title or bare 'CH n'.
  List<String> get channelTitles => effectiveSlots.channelTitles;

  bool get hasPending => _doc is _Dirty;

  /// Whether this connection has delivered its flash document.
  bool get hasDeviceDoc => _doc.flash != null;

  /// The board half of the flash document.
  BoardCalibration? get boardCalibration => _doc.flash?.board;

  /// The raw KVS snapshot as last read (refreshed by a verified save).
  KvsSnapshot? get kvsSnapshot => _doc.flash?.kvs;

  /// The connected device's display name, live off the link.
  String get connectedDeviceName => _connectedDeviceName();

  List<RigHistoryEntry> get history => List.unmodifiable(_history);

  // -- Connection events ------------------------------------------------------

  /// A flash document arrived from device [deviceId]: adopt it and record every
  /// populated slot in the cell history. Fires once per connect in practice.
  ///
  /// A second read mid-connection replaces the document; any pending edits
  /// seeded from the old document are discarded ([RigEditsDiscarded] is
  /// emitted): keeping them would apply a buffer to a document it was never
  /// diffed against, so a save could write the old document's slots to a
  /// different device.
  void onFlashRead(String deviceId, String deviceName, DeviceFlash flash) {
    // Delivery is token-gated to a live link upstream, so the document always
    // carries its device's identity.
    assert(deviceId.isNotEmpty, 'a flash read belongs to an identified device');

    final replacedDirty = _doc is _Dirty;
    if (replacedDirty) _events.emit(const RigEditsDiscarded());
    // Assert fires with the safe state already established: debug/test trips
    // loudly, release lands on the discard branch above.
    _doc = _Clean(flash);
    assert(
      !replacedDirty,
      'flash read while dirty: unsaved edits were discarded',
    );

    // Every populated slot was seen now; one persist for the batch.
    final now = DateTime.now();
    var seenAny = false;
    for (int i = 0; i < kRigSlotCount; ++i) {
      final cell = flash.slots.cellAt(i);
      if (cell != null) {
        _upsertHistory(cell, deviceName, now, persist: false);
        seenAny = true;
      }
    }
    if (seenAny) unawaited(_persistHistory());

    notifyListeners();
  }

  /// The link went away: the flash document and any unsaved edits die with the
  /// connection ([RigEditsDiscarded] is emitted for the latter).
  void onLinkDropped() {
    final doc = _doc;
    if (doc is _NoDoc) return;
    if (doc is _Dirty) _events.emit(const RigEditsDiscarded());
    _doc = const _NoDoc();
    notifyListeners();
  }

  // -- Edits (UI gestures; require a read doc — see [hasDeviceDoc]) ------------

  /// Run [edit] over the effective slots and store the result as the pending
  /// buffer, promoting a clean document to dirty. The buffer always sits next
  /// to the document it seeded from, so a save can never apply a buffer to a
  /// superseded document.
  void _edit(RigSlots Function(RigSlots base) edit) {
    _doc = switch (_doc) {
      _NoDoc() => throw StateError('edits require a read flash document'),
      _Clean(:final flash) => _Dirty(flash, edit(flash.slots)),
      _Dirty(:final flash, :final slots) => _Dirty(flash, edit(slots)),
    };
  }

  /// Place [cell] into slot [i]; recorded in history immediately.
  void setSlot(int i, LoadCellProfile cell) {
    _edit((slots) => slots.withSlot(i, RigSlot(cell: cell)));
    _upsertHistory(cell, connectedDeviceName, DateTime.now());
    notifyListeners();
  }

  /// Empty slot [i]; not recorded in history (unlike [setSlot]).
  void clearSlot(int i) {
    _edit((slots) => slots.withSlot(i, null));
    notifyListeners();
  }

  /// Swap the contents of slots [a] and [b] (the drag gesture). Insert-style
  /// reorder is not offered: a swap never shifts the list under the user's
  /// finger.
  void swapSlots(int a, int b) {
    if (a == b) return;
    _edit((slots) => slots.withSwap(a, b));
    notifyListeners();
  }

  /// Discard pending edits; the flash state becomes effective again.
  void revert() {
    final doc = _doc;
    if (doc is! _Dirty) return;
    _doc = _Clean(doc.flash);
    notifyListeners();
  }

  /// Write the edited slots to the device, then verify with a read-back. False
  /// on failure; pending edits are kept so the user can retry or revert.
  @useResult
  Future<bool> saveToDevice() async {
    final doc = _doc;
    if (doc is! _Dirty) return true;
    final edited = doc.slots;
    final backend = _backend();
    if (backend == null) {
      // Edits die with the link (see [onLinkDropped]), so a dirty state on a
      // dead link is a caller bug, not a race.
      throw StateError('saveToDevice with pending edits but no live link');
    }
    try {
      await backend.writeSlots(edited.toKv());
    } catch (_) {
      return false;
    }
    // Verify: firmware may reject, truncate, or normalize the write, and there
    // is no change detection. The equality check below catches a mangled
    // read-back.
    final KvsSnapshot readBack;
    final RigSlots verified;
    try {
      readBack = await backend.readKvsSnapshot();
      verified = RigSlots.fromKv(readBack.user);
    } catch (_) {
      return false;
    }
    if (!_sameCells(verified, edited)) return false;
    // Commit only if nothing moved under the in-flight write (an edit, a
    // re-read, or a link drop all replace the state object).
    if (!identical(_doc, doc)) return false;
    // Adopt the read-back's slots (with any normalization), the read-time
    // board, and the fresh KVS.
    _doc = _Clean(
      DeviceFlash(board: doc.flash.board, slots: verified, kvs: readBack),
    );
    notifyListeners();
    return true;
  }

  /// Compare cells slot by slot (the read-back may differ textually).
  static bool _sameCells(RigSlots a, RigSlots b) {
    for (int i = 0; i < kRigSlotCount; ++i) {
      if (a.cellAt(i) != b.cellAt(i)) return false;
    }
    return true;
  }

  // -- History persistence ------------------------------------------------------

  /// Newest-first, stable: Dart's sort is not, and ties on lastSeen are common
  /// (a flash read stamps every slot with the same now), so tie-break on the
  /// original index to keep first-seen order.
  void _sortHistory() {
    final decorated = [
      for (var i = 0; i < _history.length; ++i) (i, _history[i]),
    ];
    decorated.sort((a, b) {
      final byRecency = b.$2.lastSeen.compareTo(a.$2.lastSeen);
      return byRecency != 0 ? byRecency : a.$1.compareTo(b.$1);
    });
    _history = [for (final d in decorated) d.$2];
  }

  void _upsertHistory(
    LoadCellProfile cell,
    String deviceName,
    DateTime now, {
    bool persist = true,
  }) {
    for (final e in _history) {
      if (e.cell == cell) {
        e.lastSeen = now;
        e.deviceName = deviceName;
        _sortHistory();
        if (persist) unawaited(_persistHistory());
        return;
      }
    }
    _history.add(
      RigHistoryEntry(cell: cell, lastSeen: now, deviceName: deviceName),
    );
    _sortHistory();
    if (_history.length > historyCap) {
      _history = _history.sublist(0, historyCap);
    }
    if (persist) unawaited(_persistHistory());
  }

  Future<void> _persistHistory() => _prefs.setString(
    _keyHistory,
    jsonEncode([for (final e in _history) e.toJson()]),
  );

  void _loadHistory() {
    final raw = _prefs.getString(_keyHistory);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _history = [for (final e in decoded) ?_tryParseHistoryEntry(e)];
    } catch (e) {
      debugPrint('Failed to parse rig history: $e');
    }
  }

  /// A malformed entry drops just itself, not the whole history.
  static RigHistoryEntry? _tryParseHistoryEntry(Object? e) {
    try {
      return RigHistoryEntry.fromJson(Map<String, dynamic>.from(e! as Map));
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Document state
// ---------------------------------------------------------------------------

/// The rig's document state: nothing read yet, the document as read, or the
/// document plus an unsaved edit buffer. Sealed so "edits without a document"
/// cannot exist: the buffer lives in [_Dirty], next to the document it
/// seeded from. The state object is replaced (never mutated) on every
/// transition, so identity comparison pins a state in time (see
/// [RigState.saveToDevice]).
sealed class _DocState {
  const _DocState();

  /// The read document, when one exists.
  DeviceFlash? get flash;
}

/// No flash document read yet, or it died with the link (see
/// [RigState.onLinkDropped]).
class _NoDoc extends _DocState {
  const _NoDoc();

  @override
  Null get flash => null;
}

/// The flash document as read; no unsaved edits.
class _Clean extends _DocState {
  const _Clean(this.flash);

  @override
  final DeviceFlash flash;
}

/// The flash document plus [slots], its unsaved edit buffer (seeded from the
/// document by the first edit — see [RigState._edit]).
class _Dirty extends _DocState {
  const _Dirty(this.flash, this.slots);

  @override
  final DeviceFlash flash;

  /// The pending edit buffer.
  final RigSlots slots;
}

/// A "last seen" cell, offered as a quick pick when filling a slot. Advisory
/// app memory only; the device is the rig's truth. Identity is the profile
/// value, so two physically distinct identical cells are one entry.
class RigHistoryEntry {
  RigHistoryEntry({
    required this.cell,
    required this.lastSeen,
    required this.deviceName,
  });

  final LoadCellProfile cell;
  DateTime lastSeen;

  /// Device the entry was last seen on, for display.
  String deviceName;

  Map<String, dynamic> toJson() => {
    'cell': cell.toJson(),
    'lastSeen': lastSeen.millisecondsSinceEpoch,
    'deviceName': deviceName,
  };

  factory RigHistoryEntry.fromJson(Map<String, dynamic> json) =>
      RigHistoryEntry(
        cell: LoadCellProfile.fromJson(
          Map<String, dynamic>.from(json['cell'] as Map),
        ),
        lastSeen: DateTime.fromMillisecondsSinceEpoch(json['lastSeen'] as int),
        deviceName: json['deviceName'] as String? ?? '',
      );
}
