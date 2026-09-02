import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_profile.dart';
import '../models/display_unit.dart';

/// Application-wide settings, persisted via SharedPreferences.
///
/// Deliberately NOT here: channel labels (gone — row titles come from the
/// rig's load cell slots) and everything load cell (device slots, history —
/// owned by `RigState`).
class AppSettings extends ChangeNotifier {
  /// [prefs] is injected (see `main`): the instance is available
  /// synchronously, so the load happens right here in the constructor and
  /// can never race a later setter.
  AppSettings({required SharedPreferences prefs}) : _prefs = prefs {
    // A missing or unrecognizable stored value falls back to the platform
    // default unit (mV/V — see [_displayUnit]).
    _displayUnit = DisplayUnit.fromName(_prefs.getString(_keyUnit));

    final active = _prefs.getStringList(_keyActiveChannels);
    if (active != null && active.length == kAdcChannelCount) {
      _activeChannels = active.map((s) => s == 'true').toList();
    }

    _wakelockEnabled = _prefs.getBool(_keyWakelock) ?? false;
  }

  static const String _keyUnit = 'display_unit';
  static const String _keyActiveChannels = 'active_channels';
  static const String _keyWakelock = 'wakelock_enabled';

  final SharedPreferences _prefs;

  // mV/V is the default: it converts with board calibration alone, so a
  // fresh install shows meaningful numbers before any load cell is assigned
  // (force units need per-channel load-cell profiles).
  DisplayUnit _displayUnit = DisplayUnit.mVv;
  DisplayUnit get displayUnit => _displayUnit;

  /// Which channels are shown in the live view. Local to the live tab —
  /// each recorded session carries its own visibility set.
  List<bool> _activeChannels = List.filled(kAdcChannelCount, true);
  List<bool> get activeChannels => List.unmodifiable(_activeChannels);

  List<int> get activeChannelIndices => [
    for (int i = 0; i < _activeChannels.length; i++)
      if (_activeChannels[i]) i,
  ];

  bool _wakelockEnabled = false;
  bool get wakelockEnabled => _wakelockEnabled;

  Future<void> setDisplayUnit(DisplayUnit unit) async {
    _displayUnit = unit;
    notifyListeners();
    await _prefs.setString(_keyUnit, unit.name);
  }

  Future<void> setChannelActive(int index, bool active) async {
    _activeChannels[index] = active;
    notifyListeners();
    await _prefs.setStringList(
      _keyActiveChannels,
      _activeChannels.map((b) => b.toString()).toList(),
    );
  }

  Future<void> setWakelockEnabled(bool enabled) async {
    _wakelockEnabled = enabled;
    notifyListeners();
    await _prefs.setBool(_keyWakelock, enabled);
  }
}
