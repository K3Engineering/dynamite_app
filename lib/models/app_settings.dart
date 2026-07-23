import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/adc_protocol.dart';
import 'calibration.dart';
import 'force_unit.dart';

/// Application-wide settings, persisted via SharedPreferences.
class AppSettings extends ChangeNotifier {
  static const String _keyUnit = 'display_unit';
  static const String _keyChannelLabels = 'channel_labels';
  static const String _keyActiveChannels = 'active_channels';
  static const String _keyWakelock = 'wakelock_enabled';
  static const String _keyLoadCellBank = 'load_cell_bank';
  static const String _keyChannelLoadCells = 'channel_load_cells';

  // mV/V is the default: it converts with board calibration alone, so a
  // fresh install shows meaningful numbers before any load cell is assigned
  // (force units need per-channel load-cell profiles).
  ForceUnit _displayUnit = ForceUnit.mVv;
  ForceUnit get displayUnit => _displayUnit;

  /// Labels for each of the [nwNumAdcChan] ADC channels.
  List<String> _channelLabels = [
    for (int i = 0; i < nwNumAdcChan; i++) 'Load Cell ${i + 1}',
  ];
  List<String> get channelLabels => List.unmodifiable(_channelLabels);

  /// Which channels are shown in the live view. Local to the live tab —
  /// each recorded session carries its own visibility set.
  List<bool> _activeChannels = List.filled(nwNumAdcChan, true);
  List<bool> get activeChannels => List.unmodifiable(_activeChannels);

  /// Indices of active channels.
  List<int> get activeChannelIndices => [
    for (int i = 0; i < _activeChannels.length; i++)
      if (_activeChannels[i]) i,
  ];

  bool _wakelockEnabled = false;
  bool get wakelockEnabled => _wakelockEnabled;

  /// The user's load cell library. Channels reference entries by id; an
  /// entry's edits surface on every channel using it.
  List<LoadCellProfile> _loadCellBank = [];
  List<LoadCellProfile> get loadCellBank => List.unmodifiable(_loadCellBank);

  /// Profile id assigned to each channel, or null: unassigned channels show
  /// electrical units only (force conversions report unavailable).
  List<String?> _channelLoadCellIds = List.filled(nwNumAdcChan, null);
  List<String?> get channelLoadCellIds =>
      List.unmodifiable(_channelLoadCellIds);

  /// The profile assigned to channel [ch], or null (unassigned or a dangling
  /// id — e.g. just after its profile was deleted).
  LoadCellProfile? loadCellForChannel(int ch) {
    final id = _channelLoadCellIds[ch];
    if (id == null) return null;
    for (final p in _loadCellBank) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Resolved per-channel assignments, in channel order (nulls included).
  List<LoadCellProfile?> get channelLoadCells => [
    for (int i = 0; i < nwNumAdcChan; i++) loadCellForChannel(i),
  ];

  /// Preference keys the user has explicitly set through a setter. [_load]'s
  /// async read resolves AFTER the constructor returns, so a setter that ran
  /// in the meantime owns the in-memory value — [_load] must not overwrite it
  /// with the (older) persisted one.
  final Set<String> _modifiedKeys = {};

  AppSettings() {
    unawaited(_load());
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();

    final unitName = prefs.getString(_keyUnit);
    if (unitName != null && !_modifiedKeys.contains(_keyUnit)) {
      _displayUnit = ForceUnit.values.firstWhere(
        (u) => u.name == unitName,
        orElse: () => ForceUnit.mVv,
      );
    }

    final labels = prefs.getStringList(_keyChannelLabels);
    if (labels != null &&
        labels.length == nwNumAdcChan &&
        !_modifiedKeys.contains(_keyChannelLabels)) {
      _channelLabels = labels;
    }

    final active = prefs.getStringList(_keyActiveChannels);
    if (active != null &&
        active.length == nwNumAdcChan &&
        !_modifiedKeys.contains(_keyActiveChannels)) {
      _activeChannels = active.map((s) => s == 'true').toList();
    }

    if (!_modifiedKeys.contains(_keyWakelock)) {
      _wakelockEnabled = prefs.getBool(_keyWakelock) ?? false;
    }

    if (!_modifiedKeys.contains(_keyLoadCellBank)) {
      final bankJson = prefs.getString(_keyLoadCellBank);
      if (bankJson != null) {
        try {
          final decoded = jsonDecode(bankJson);
          if (decoded is List) {
            _loadCellBank = [
              for (final e in decoded)
                if (e is Map)
                  LoadCellProfile.fromJson(Map<String, dynamic>.from(e)),
            ];
          }
        } catch (e) {
          debugPrint('Failed to parse load cell bank: $e');
        }
      }
    }

    if (!_modifiedKeys.contains(_keyChannelLoadCells)) {
      final idsJson = prefs.getString(_keyChannelLoadCells);
      if (idsJson != null) {
        try {
          final decoded = jsonDecode(idsJson);
          if (decoded is List && decoded.length == nwNumAdcChan) {
            _channelLoadCellIds = [
              for (final e in decoded) e is String ? e : null,
            ];
          }
        } catch (e) {
          debugPrint('Failed to parse channel load cell assignments: $e');
        }
      }
    }

    notifyListeners();
  }

  Future<void> setDisplayUnit(ForceUnit unit) async {
    _modifiedKeys.add(_keyUnit);
    _displayUnit = unit;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUnit, unit.name);
  }

  Future<void> setChannelLabel(int index, String label) async {
    _modifiedKeys.add(_keyChannelLabels);
    _channelLabels[index] = label;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyChannelLabels, _channelLabels);
  }

  Future<void> setChannelActive(int index, bool active) async {
    _modifiedKeys.add(_keyActiveChannels);
    _activeChannels[index] = active;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyActiveChannels,
      _activeChannels.map((b) => b.toString()).toList(),
    );
  }

  Future<void> setWakelockEnabled(bool enabled) async {
    _modifiedKeys.add(_keyWakelock);
    _wakelockEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyWakelock, enabled);
  }

  // -- Load cell bank and per-channel assignment -----------------------------

  /// Mint a bank-unique profile id. Microsecond-clock based; collisions are
  /// practically impossible via UI pacing.
  String mintLoadCellId() => 'lc${DateTime.now().microsecondsSinceEpoch}';

  /// Add a profile to the bank, or replace the one with the same id (edits
  /// propagate to every channel using it).
  Future<void> saveLoadCell(LoadCellProfile cell) async {
    _modifiedKeys.add(_keyLoadCellBank);
    final idx = _loadCellBank.indexWhere((p) => p.id == cell.id);
    if (idx >= 0) {
      _loadCellBank[idx] = cell;
    } else {
      _loadCellBank.add(cell);
    }
    notifyListeners();
    await _persistBank();
  }

  /// Find an existing generic profile (unnamed, uncorrected) with exactly
  /// these values, or create one — quick-pick assignment never litters the
  /// bank with duplicates.
  Future<LoadCellProfile> findOrCreateGenericCell({
    required double capacityKg,
    required double sensitivityMvV,
  }) async {
    for (final p in _loadCellBank) {
      if (p.name.isEmpty &&
          p.capacityKg == capacityKg &&
          p.sensitivityMvV == sensitivityMvV &&
          p.span == 1.0) {
        return p;
      }
    }
    final cell = LoadCellProfile(
      id: mintLoadCellId(),
      capacityKg: capacityKg,
      sensitivityMvV: sensitivityMvV,
    );
    await saveLoadCell(cell);
    return cell;
  }

  /// Remove a profile from the bank. Channels referencing it fall back to
  /// unassigned (electrical units only).
  Future<void> deleteLoadCell(String id) async {
    _modifiedKeys.add(_keyLoadCellBank);
    _loadCellBank.removeWhere((p) => p.id == id);
    var assignmentsChanged = false;
    for (int i = 0; i < _channelLoadCellIds.length; i++) {
      if (_channelLoadCellIds[i] == id) {
        _channelLoadCellIds[i] = null;
        assignmentsChanged = true;
      }
    }
    if (assignmentsChanged) _modifiedKeys.add(_keyChannelLoadCells);
    notifyListeners();
    await _persistBank();
    if (assignmentsChanged) await _persistAssignments();
  }

  /// Assign a profile (or null = unassigned) to a channel.
  Future<void> assignLoadCell(int channel, String? profileId) async {
    _modifiedKeys.add(_keyChannelLoadCells);
    _channelLoadCellIds[channel] = profileId;
    notifyListeners();
    await _persistAssignments();
  }

  /// Channels (1-based labels) currently assigned profile [id] — for the
  /// delete confirmation's "in use" warning.
  List<int> channelsUsing(String id) => [
    for (int i = 0; i < _channelLoadCellIds.length; i++)
      if (_channelLoadCellIds[i] == id) i + 1,
  ];

  Future<void> _persistBank() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyLoadCellBank,
      jsonEncode([for (final p in _loadCellBank) p.toJson()]),
    );
  }

  Future<void> _persistAssignments() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyChannelLoadCells,
      jsonEncode(_channelLoadCellIds),
    );
  }
}
