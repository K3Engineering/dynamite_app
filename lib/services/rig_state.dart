import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/calibration.dart';

/// The piece of the BLE stack [RigState] needs: which device is connected,
/// and a way to write the whole flash document back to it. Implemented by
/// `BleLinkManager` (demo device mutates an in-memory doc; real devices go
/// through the device KVS — see `KvsFlashTransport`).
abstract interface class RigFlashTransport {
  /// Empty string when no device is connected.
  String get connectedDeviceId;

  /// Display name of the connected device ('' when none).
  String get connectedDeviceName;

  /// Write a serialized [DeviceFlash] document to the connected device.
  /// Throws on failure — the caller keeps its pending edits.
  Future<void> writeFlashDoc(String doc);

  /// Read the flash document back from the connected device (save
  /// verification). Null on failure or when no device is connected.
  Future<String?> readFlashDoc();
}

/// A "last seen values" entry: a cell this app has met (on a device flash
/// read, or typed in by the user), offered as a quick pick when filling an
/// empty slot. Purely advisory app memory — the device is the rig's truth.
class RigHistoryEntry {
  RigHistoryEntry({
    required this.cell,
    required this.lastSeen,
    required this.deviceName,
  });

  final LoadCellProfile cell;
  DateTime lastSeen;

  /// Device the entry was last seen on (or added on), for display.
  String deviceName;

  Map<String, dynamic> toJson() => {
    'cell': cell.toJson(),
    'lastSeen': lastSeen.millisecondsSinceEpoch,
    'deviceName': deviceName,
  };

  /// Tolerant of extra keys (older versions persisted an 'origin' field).
  factory RigHistoryEntry.fromJson(Map<String, dynamic> json) =>
      RigHistoryEntry(
        cell: LoadCellProfile.fromJson(
          Map<String, dynamic>.from(json['cell'] as Map),
        ),
        lastSeen: DateTime.fromMillisecondsSinceEpoch(json['lastSeen'] as int),
        deviceName: json['deviceName'] as String? ?? '',
      );
}

/// Unsaved slot edits. In-memory ONLY (never persisted): they survive a
/// device disconnect for the SAME device (restored on reconnect, see
/// [RigState.onFlashRead]), but an app restart drops them — by design, so a
/// stale edit can never resurface days later against an unknown rig.
class PendingRigEdits {
  PendingRigEdits({
    required this.deviceId,
    required this.base,
    required this.edited,
  });

  final String deviceId;

  /// The flash state the edits are based on. If a reconnect finds the device
  /// no longer matches this, the edits are stale and get discarded.
  final RigSlots base;

  /// The edited slot list (what the app's readings already use).
  RigSlots edited;
}

/// Owns the rig: the slot list read from the connected device, unsaved
/// edits, and the cross-device cell history.
///
/// The model is deliberately low-state: the device flash is the ONLY rig
/// truth; this class adds (a) pending edits the user hasn't saved yet and
/// (b) advisory history that can inform but never competes with the device.
class RigState extends ChangeNotifier {
  /// [prefs] is injected (see `main`): the instance is available
  /// synchronously, so the history load happens right here in the
  /// constructor and can never race a later setter.
  RigState({
    required RigFlashTransport transport,
    required SharedPreferences prefs,
  }) : _transport = transport,
       _prefs = prefs {
    // Keys of removed subsystems (per-device change detection, the DMM
    // cross-check), erased on load; there are no field devices, so no
    // migration is performed.
    for (final key in _legacyKeys) {
      unawaited(_prefs.remove(key));
    }
    _loadHistory();
  }

  static const String _keyHistory = 'rig_history';
  static const List<String> _legacyKeys = [
    'rig_lastseen',
    'rig_dmm_excitation_mv',
  ];

  /// History is a suggestion list, not an archive — cap it so it stays
  /// scannable (least-recently-seen evicted).
  static const int historyCap = 50;

  final RigFlashTransport _transport;
  final SharedPreferences _prefs;

  /// The flash document as last read from the connected device (board +
  /// slots). Null before the first successful read of this run — and save is
  /// IMPOSSIBLE without it: the board keys round-trip verbatim through a
  /// save, so writing without a prior read would stamp nominal board values
  /// over real factory data.
  DeviceFlash? _lastFlash;

  /// The device [_lastFlash] was read from. Kept (with the doc) across
  /// disconnects, so edits made while offline still attach to the right
  /// device and a later reconnect can restore the pending session.
  String _flashDeviceId = '';

  /// Display name of [_flashDeviceId] at read time ('' when unknown) — for
  /// surfaces that must name the document's owner (the calibration report).
  String _flashDeviceName = '';

  PendingRigEdits? _pending;

  List<RigHistoryEntry> _history = [];

  // -- Reads -----------------------------------------------------------------

  /// The slot list driving the UI and conversions: pending edits when dirty,
  /// else the device's flash state (empty before the first read).
  RigSlots get effectiveSlots =>
      _pending?.edited ?? _lastFlash?.slots ?? RigSlots.empty();

  /// Cells converting the four channels (slots 0–3 of [effectiveSlots]).
  List<LoadCellProfile?> get channelCells => effectiveSlots.channelCells;

  /// Live-view row titles: cell title or bare 'CH n'.
  List<String> get channelTitles => effectiveSlots.channelTitles;

  PendingRigEdits? get pending => _pending;
  bool get hasPending => _pending != null;

  /// Whether a flash document has been read this run. The slot UI and saves
  /// are gated on this (see [_lastFlash]).
  bool get hasDeviceDoc => _lastFlash != null;

  /// The board half of the flash document, but only while the document
  /// belongs to [deviceId]: null before the first read of this run, and
  /// null while the document on file came from ANOTHER device (it is kept
  /// across disconnects — see [_flashDeviceId]). The settings UI's single
  /// ownership query, decided HERE by the document owner: the hub's
  /// conversion-side snapshot is never the UI's source, so what renders
  /// always belongs to an identified device.
  BoardCalibration? boardCalibrationFor(String deviceId) {
    final flash = _lastFlash;
    if (flash == null || _flashDeviceId != deviceId) return null;
    return flash.board;
  }

  /// The display name of the device the flash document belongs to — the
  /// same ownership rule as [boardCalibrationFor]: '' for another device's
  /// document or before the first read.
  String deviceNameFor(String deviceId) =>
      _flashDeviceId == deviceId ? _flashDeviceName : '';

  List<RigHistoryEntry> get history => List.unmodifiable(_history);

  // -- Flash reads (connect time) ---------------------------------------------

  /// A flash document just arrived from device [deviceId] (named
  /// [deviceName]): adopt it as the rig truth, restore or discard matching
  /// pending edits, and record every populated slot in the cell history.
  void onFlashRead(String deviceId, String deviceName, DeviceFlash flash) {
    // A link that dropped mid-read delivers with no identity — without an
    // owning device id the document can't be attributed to anything.
    if (deviceId.isEmpty) return;

    // Pending edits: restore only when they belong to this device AND the
    // device still matches their base. A changed device makes them stale —
    // discard rather than resurrect an edit based on a rig that no longer
    // exists.
    final pending = _pending;
    if (pending != null &&
        !(pending.deviceId == deviceId &&
            _sameCells(pending.base, flash.slots))) {
      _pending = null;
    }

    _lastFlash = flash;
    _flashDeviceId = deviceId;
    _flashDeviceName = deviceName;

    // History: every populated slot on the device was "seen" now. One
    // persist for the batch, not one per cell.
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

  /// Content comparison for the pending-restore check: a pure rewrite with
  /// fresh mtimes is NOT a change, so compare the cells, not the slots.
  static bool _sameCells(RigSlots a, RigSlots b) {
    for (int i = 0; i < kRigSlotCount; ++i) {
      if (a.cellAt(i) != b.cellAt(i)) return false;
    }
    return true;
  }

  // -- Edits (UI gestures; require a read doc — see [hasDeviceDoc]) ------------

  /// Start (if needed) the pending-edit session. Edits attach to the device
  /// the flash doc came from (which may be offline right now — see
  /// [_flashDeviceId]).
  PendingRigEdits _ensurePending() {
    final flash = _lastFlash;
    assert(flash != null, 'edits require a read flash document');
    return _pending ??= PendingRigEdits(
      deviceId: _flashDeviceId,
      base: flash!.slots,
      edited: flash.slots,
    );
  }

  /// Place [cell] into slot [i] (add or edit). Recorded in history
  /// immediately: typed-in values are exactly what "last seen" is for.
  void setSlot(int i, LoadCellProfile cell) {
    final p = _ensurePending();
    p.edited = p.edited.withSlot(i, RigSlot(cell: cell));
    _upsertHistory(cell, _transport.connectedDeviceName, DateTime.now());
    notifyListeners();
  }

  /// Empty slot [i]. Not recorded in history (contrast [setSlot]): an
  /// emptied slot is not a reusable "last seen" value.
  void clearSlot(int i) {
    final p = _ensurePending();
    p.edited = p.edited.withSlot(i, null);
    notifyListeners();
  }

  /// Insert-style reorder is deliberately NOT offered: the drag gesture is a
  /// swap — dragging a cell onto another slot exchanges their contents, so
  /// the list never shifts under the user's finger.
  void swapSlots(int a, int b) {
    if (a == b) return;
    final p = _ensurePending();
    p.edited = p.edited.withSwap(a, b);
    notifyListeners();
  }

  /// Discard pending edits; the flash state becomes effective again.
  void revert() {
    if (_pending == null) return;
    _pending = null;
    notifyListeners();
  }

  /// Write the edited slots (with fresh mtimes) to the device, alongside the
  /// board keys exactly as read, then verify with a read-back. Returns false
  /// when the write or the verification fails — pending edits are kept so
  /// the user can retry or revert.
  Future<bool> saveToDevice() async {
    final pending = _pending;
    final flash = _lastFlash;
    if (pending == null || flash == null) return true;
    // The write must go to the device the edits belong to — anything else
    // would stamp this document's factory board keys onto another device's
    // flash. The UI gates the Save button on this; the check belongs here
    // too, next to the write.
    if (pending.deviceId != _transport.connectedDeviceId) return false;
    final edited = pending.edited;
    final now = DateTime.now().toUtc();
    final stamped = RigSlots([
      for (int i = 0; i < kRigSlotCount; ++i)
        edited.slots[i]?.copyWith(mtime: now),
    ]);
    final doc = DeviceFlash(
      board: flash.board,
      slots: stamped,
      extraLines: flash.extraLines,
    ).serialize();
    try {
      await _transport.writeFlashDoc(doc);
    } catch (_) {
      return false;
    }
    // Verify: "the device holds exactly what we wrote" is an assumption,
    // not a fact (firmware may reject, truncate or normalize the write).
    // Adopting the composed document as truth without checking would let
    // app state diverge from the device silently — and there is no later
    // change detection to catch it.
    final String? readBack;
    try {
      readBack = await _transport.readFlashDoc();
    } catch (_) {
      return false;
    }
    if (readBack == null) return false;
    final verified = DeviceFlash.parse(readBack);
    if (!_sameCells(verified.slots, stamped)) return false;
    // Commit only if nothing moved under the in-flight write: a revert, a
    // fresh edit, or a reconnect's flash read means the newer state wins.
    // (The UI also blocks edits while saving; this is the model-side guard.)
    if (!identical(_pending, pending) ||
        !identical(pending.edited, edited) ||
        !identical(_lastFlash, flash)) {
      return false;
    }
    // The device provably holds this document — adopt the READ-BACK version
    // as the new flash truth (not the composed one), so any normalization
    // the device applied is reflected in app state too.
    _lastFlash = verified;
    _pending = null;
    notifyListeners();
    return true;
  }

  // -- History persistence ------------------------------------------------------

  /// Newest-first ordering for [_history], made STABLE: Dart's List.sort is
  /// not, and ties on lastSeen are the common case — a flash read stamps
  /// every populated slot with the same `now` (see [onFlashRead]) — so an
  /// unstable sort could permute equally-recent entries on every upsert,
  /// churning the "Last seen in this app" picker's order. Decorate with the
  /// current index and tie-break on it, preserving first-seen order among
  /// ties.
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

  /// One malformed entry drops just that entry, not the whole history.
  static RigHistoryEntry? _tryParseHistoryEntry(Object? e) {
    try {
      return RigHistoryEntry.fromJson(Map<String, dynamic>.from(e as Map));
    } catch (_) {
      return null;
    }
  }
}
