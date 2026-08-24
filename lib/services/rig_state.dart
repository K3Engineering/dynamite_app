import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/board_calibration.dart';
import '../models/device_flash.dart';
import '../models/load_cell.dart';
import 'rig_flash_transport.dart';

/// Owns the rig: the slot list read from the connected device, unsaved
/// edits, and the cross-device cell history.
///
/// The model is deliberately low-state, built around two use cases:
///
/// * Several people share one device: rig data should travel with the
///   hardware - a new person in a lab gets all the saved LC data.
/// * One person moves a load cell between devices: [history] remembers
///   every cell this app has met, so setting up the receiving device
///   offers the cell as a one-tap pick instead of a re-type. History
///   informs new slots; it never feeds device state.
///
/// Unsaved edits live die with a disconnect. Typed-in
/// cell values survive in [history] (recorded at edit time),
/// so a discard costs a few slot gestures, not the re-typing
class RigState extends ChangeNotifier {
  /// [prefs] is injected (see `main`): the instance is available
  /// synchronously, so the history load happens right here in the
  /// constructor and can never race a later setter.
  RigState({
    required RigFlashTransport transport,
    required SharedPreferences prefs,
  }) : _transport = transport,
       _prefs = prefs {
    _loadHistory();
  }

  static const String _keyHistory = 'rig_history';

  /// History is a suggestion list, not an archive — cap it so it stays
  /// scannable (least-recently-seen evicted).
  static const int historyCap = 50;

  final RigFlashTransport _transport;
  final SharedPreferences _prefs;

  /// The flash document as last read from the connected device (board +
  /// slots). Null before this connection's first successful read — and
  /// save is IMPOSSIBLE without it: the board keys round-trip verbatim
  /// through a save, so writing without a prior read would stamp nominal
  /// board values over real factory data. Also null after
  /// [onLinkDropped]: the document is a claim about the device's current
  /// contents, which a dead link cannot back.
  DeviceFlash? _lastFlash;

  /// Unsaved slot edits — what the app's readings already use. Null when
  /// clean. Dies with the link ([onLinkDropped]); nothing reaches the
  /// device until [saveToDevice].
  RigSlots? _pendingEdits;

  List<RigHistoryEntry> _history = [];

  // -- Reads -----------------------------------------------------------------

  /// The slot list driving the UI and conversions: pending edits when
  /// dirty, else the device's flash state (empty before the first read).
  RigSlots get effectiveSlots =>
      _pendingEdits ?? _lastFlash?.slots ?? RigSlots.empty();

  /// Cells converting the four channels (slots 0–3 of [effectiveSlots]).
  List<LoadCellProfile?> get channelCells => effectiveSlots.channelCells;

  /// Live-view row titles: cell title or bare 'CH n'.
  List<String> get channelTitles => effectiveSlots.channelTitles;

  bool get hasPending => _pendingEdits != null;

  /// Whether this connection has delivered its flash document. The slot
  /// UI and saves are gated on this (see [_lastFlash]).
  bool get hasDeviceDoc => _lastFlash != null;

  /// The board half of the flash document; null before this connection's
  /// first successful read.
  BoardCalibration? get boardCalibration => _lastFlash?.board;

  /// The connected device's display name, live off the link: history
  /// provenance and the calibration report's owner label.
  String get connectedDeviceName => _transport.connectedDeviceName;

  List<RigHistoryEntry> get history => List.unmodifiable(_history);

  // -- Connection events ------------------------------------------------------

  /// A flash document just arrived from device [deviceId] (named
  /// [deviceName]): adopt it as the rig truth and record every populated
  /// slot in the cell history. Fires once per connect; nothing from the
  /// previous connection is around to reconcile — the link's death
  /// cleared it ([onLinkDropped]).
  void onFlashRead(String deviceId, String deviceName, DeviceFlash flash) {
    // Delivery is token-gated to a live link upstream (BleLinkManager),
    // so the document always arrives with its owning device's identity.
    assert(deviceId.isNotEmpty, 'a flash read belongs to an identified device');

    _lastFlash = flash;

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

  /// The link went away (user disconnect, drop, teardown — one event as
  /// far as the rig is concerned): the flash document and any unsaved
  /// edits die with the connection.
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

  /// Place [cell] into slot [i] (add or edit). Recorded in history
  /// immediately: typed-in values are exactly what "last seen" is for.
  void setSlot(int i, LoadCellProfile cell) {
    _pendingEdits = _editBuffer().withSlot(i, RigSlot(cell: cell));
    _upsertHistory(cell, _transport.connectedDeviceName, DateTime.now());
    notifyListeners();
  }

  /// Empty slot [i]. Not recorded in history (contrast [setSlot]): an
  /// emptied slot is not a reusable "last seen" value.
  void clearSlot(int i) {
    _pendingEdits = _editBuffer().withSlot(i, null);
    notifyListeners();
  }

  /// Insert-style reorder is deliberately NOT offered: the drag gesture is a
  /// swap — dragging a cell onto another slot exchanges their contents, so
  /// the list never shifts under the user's finger.
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

  /// Write the edited slots to the device, alongside the board keys
  /// exactly as read, then verify with a read-back. Returns false when
  /// the write or the verification fails — pending edits are kept so the
  /// user can retry or revert.
  Future<bool> saveToDevice() async {
    final edited = _pendingEdits;
    final flash = _lastFlash;
    if (edited == null) return true;
    // Pending edits imply a read document (see [_editBuffer]), and both
    // die with the link — so the document provably belongs to the device
    // this write goes to.
    assert(flash != null, 'pending edits imply a read flash document');
    final doc = DeviceFlash(
      board: flash!.board,
      slots: edited,
      extraLines: flash.extraLines,
    ).serialize();
    try {
      await _transport.writeFlashDoc(doc);
    } catch (_) {
      return false;
    }
    // Verify: "the device holds exactly what we wrote" is an assumption,
    // not a fact (firmware may reject, truncate or normalize the write).
    // Committing without checking would let app state diverge from the
    // device silently — and there is no change detection to catch it.
    final String? readBack;
    try {
      readBack = await _transport.readFlashDoc();
    } catch (_) {
      return false;
    }
    if (readBack == null) return false;
    // Verify against the slot keys only — the write can't have changed
    // board keys, so a board re-parse would add nothing while resolving
    // constants to nominal (the read-back isn't accompanied by the ADC's
    // PGA readback).
    final verified = RigSlots.fromKv(parseFlashKv(readBack));
    if (!_sameCells(verified, edited)) return false;
    // Commit only if nothing moved under the in-flight write: a revert, a
    // fresh edit, or a link drop means the newer state wins. (The UI also
    // blocks edits while saving; this is the model-side guard.)
    if (!identical(_pendingEdits, edited) || !identical(_lastFlash, flash)) {
      return false;
    }
    // The device provably holds these slots: adopt the read-back's slot
    // list (any normalization the device applied is reflected), keep the
    // read-time board and extra lines.
    _lastFlash = DeviceFlash(
      board: flash.board,
      slots: verified,
      extraLines: flash.extraLines,
    );
    _pendingEdits = null;
    notifyListeners();
    return true;
  }

  /// The save verification's equality: the read-back may differ textually
  /// (key order, formatting), so compare the cells slot by slot.
  static bool _sameCells(RigSlots a, RigSlots b) {
    for (int i = 0; i < kRigSlotCount; ++i) {
      if (a.cellAt(i) != b.cellAt(i)) return false;
    }
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

/// A "last seen values" entry: a cell this app has met (on a device flash
/// read, or typed in by the user), offered as a quick pick when filling an
/// empty slot. This is the mechanism for moving a cell from one device to
/// another: it was seen on the source device, and the receiving device's
/// slot editor offers it back.
///
/// Purely advisory app memory — the device is the rig's truth; history
/// never feeds device state. Identity is the profile VALUE (see
/// [LoadCellProfile.==]), so two physically distinct cells with identical
/// name/capacity/sensitivity are one entry — acceptable for a suggestion
/// list.
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
