import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/board_calibration.dart';
import '../models/device_flash.dart';
import '../models/load_cell.dart';
import 'link_backend.dart';

/// Owns the rig: the slot list read from the connected device, unsaved edits,
/// and the cross-device cell history. Unsaved edits die with a disconnect;
/// typed-in cell values survive in [history].
class RigState extends ChangeNotifier {
  /// [backend] yields the active link's device operations; [prefs] is injected
  /// so history loads synchronously in the constructor.
  RigState({
    required LinkBackend? Function() backend,
    required String Function() connectedDeviceName,
    required SharedPreferences prefs,
  }) : _backend = backend,
       _connectedDeviceName = connectedDeviceName,
       _prefs = prefs {
    _loadHistory();
  }

  static const String _keyHistory = 'rig_history';

  /// History is a suggestion list, not an archive; least-recently-seen evicted.
  static const int historyCap = 50;

  final LinkBackend? Function() _backend;
  final String Function() _connectedDeviceName;
  final SharedPreferences _prefs;

  /// The flash document as last read from the connected device; null before the
  /// first read and after [onLinkDropped]. Edits buffer from this, so save is
  /// impossible without it.
  DeviceFlash? _lastFlash;

  /// Unsaved slot edits; null when clean. Die with the link.
  RigSlots? _pendingEdits;

  List<RigHistoryEntry> _history = [];

  // -- Reads -----------------------------------------------------------------

  /// Pending edits when dirty, else the device's flash state.
  RigSlots get effectiveSlots =>
      _pendingEdits ?? _lastFlash?.slots ?? RigSlots.empty();

  /// Cells converting the four channels (slots 0–3 of [effectiveSlots]).
  List<LoadCellProfile?> get channelCells => effectiveSlots.channelCells;

  /// Live-view row titles: cell title or bare 'CH n'.
  List<String> get channelTitles => effectiveSlots.channelTitles;

  bool get hasPending => _pendingEdits != null;

  /// Whether this connection has delivered its flash document.
  bool get hasDeviceDoc => _lastFlash != null;

  /// The board half of the flash document.
  BoardCalibration? get boardCalibration => _lastFlash?.board;

  /// The raw KVS snapshot as last read (refreshed by a verified save).
  KvsSnapshot? get kvsSnapshot => _lastFlash?.kvs;

  /// The connected device's display name, live off the link.
  String get connectedDeviceName => _connectedDeviceName();

  List<RigHistoryEntry> get history => List.unmodifiable(_history);

  // -- Connection events ------------------------------------------------------

  /// A flash document arrived from device [deviceId]: adopt it and record every
  /// populated slot in the cell history. Fires once per connect.
  void onFlashRead(String deviceId, String deviceName, DeviceFlash flash) {
    // Delivery is token-gated to a live link upstream, so the document always
    // carries its device's identity.
    assert(deviceId.isNotEmpty, 'a flash read belongs to an identified device');

    _lastFlash = flash;

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
  /// connection.
  void onLinkDropped() {
    if (_lastFlash == null && _pendingEdits == null) return;
    _lastFlash = null;
    _pendingEdits = null;
    notifyListeners();
  }

  // -- Edits (UI gestures; require a read doc — see [hasDeviceDoc]) ------------

  /// The slot list an edit applies to: the pending buffer, started from
  /// the flash state by the first edit.
  RigSlots _editBuffer() {
    final flash = _lastFlash;
    assert(flash != null, 'edits require a read flash document');
    return _pendingEdits ??= flash!.slots;
  }

  /// Place [cell] into slot [i]; recorded in history immediately.
  void setSlot(int i, LoadCellProfile cell) {
    _pendingEdits = _editBuffer().withSlot(i, RigSlot(cell: cell));
    _upsertHistory(cell, connectedDeviceName, DateTime.now());
    notifyListeners();
  }

  /// Empty slot [i]; not recorded in history (unlike [setSlot]).
  void clearSlot(int i) {
    _pendingEdits = _editBuffer().withSlot(i, null);
    notifyListeners();
  }

  /// Swap the contents of slots [a] and [b] (the drag gesture). Insert-style
  /// reorder is not offered: a swap never shifts the list under the user's
  /// finger.
  void swapSlots(int a, int b) {
    if (a == b) return;
    _pendingEdits = _editBuffer().withSwap(a, b);
    notifyListeners();
  }

  /// Discard pending edits; the flash state becomes effective again.
  void revert() {
    if (_pendingEdits == null) return;
    _pendingEdits = null;
    notifyListeners();
  }

  /// Write the edited slots to the device, then verify with a read-back. False
  /// on failure; pending edits are kept so the user can retry or revert.
  Future<bool> saveToDevice() async {
    final edited = _pendingEdits;
    final flash = _lastFlash;
    if (edited == null) return true;
    // Pending edits imply a read document, and both die with the link.
    assert(flash != null, 'pending edits imply a read flash document');
    final backend = _backend();
    if (backend == null) {
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
    // Commit only if nothing moved under the in-flight write.
    if (!identical(_pendingEdits, edited) || !identical(_lastFlash, flash)) {
      return false;
    }
    // Adopt the read-back's slots (with any normalization), the read-time
    // board, and the fresh KVS.
    _lastFlash = DeviceFlash(
      board: flash!.board,
      slots: verified,
      kvs: readBack,
    );
    _pendingEdits = null;
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
      return RigHistoryEntry.fromJson(Map<String, dynamic>.from(e as Map));
    } catch (_) {
      return null;
    }
  }
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
