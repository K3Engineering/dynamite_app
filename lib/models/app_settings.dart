import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/adc_protocol.dart';
import 'display_unit.dart';

/// Application-wide settings, persisted via SharedPreferences.
///
/// Deliberately NOT here: channel labels (gone — row titles come from the
/// rig's load cell slots) and everything load cell (device slots, history —
/// owned by `RigState`). Legacy keys from the pre-slot model are erased on
/// load; there are no field devices, so no migration is performed.
class AppSettings extends ChangeNotifier {
  /// [prefs] is injected (see `main`): the instance is available
  /// synchronously, so the load happens right here in the constructor and
  /// can never race a later setter.
  AppSettings({required SharedPreferences prefs}) : _prefs = prefs {
    for (final key in _legacyKeys) {
      unawaited(_prefs.remove(key));
    }

    // A missing or unrecognizable stored value falls back to the platform
    // default unit (mV/V — see [_displayUnit]).
    _displayUnit = DisplayUnit.fromName(_prefs.getString(_keyUnit));

    final active = _prefs.getStringList(_keyActiveChannels);
    if (active != null && active.length == nwNumAdcChan) {
      _activeChannels = active.map((s) => s == 'true').toList();
    }

    _wakelockEnabled = _prefs.getBool(_keyWakelock) ?? false;

    _lcWarnFraction = (_prefs.getDouble(_keyLcWarnFraction) ??
            defaultLcWarnFraction)
        .clamp(minLcWarnFraction, maxLcWarnFraction);

    _limitWarningsEnabled = _prefs.getBool(_keyLimitWarnings) ?? true;
  }

  static const String _keyUnit = 'display_unit';
  static const String _keyActiveChannels = 'active_channels';
  static const String _keyWakelock = 'wakelock_enabled';
  static const String _keyLcWarnFraction = 'lc_warn_fraction';
  static const String _keyLimitWarnings = 'limit_warnings_enabled';

  /// Fraction of full scale where a channel's mild ("caution") limit warning
  /// starts; the full warning is always at 100%. Applies to the load cell
  /// rating and, with no cell assigned, to the ADC full-scale range.
  static const double defaultLcWarnFraction = 0.8;
  static const double minLcWarnFraction = 0.5;
  static const double maxLcWarnFraction = 0.95;

  /// Keys of the pre-slot model (channel labels, load cell bank, per-channel
  /// assignments, the app-global DMM reading), erased on load.
  static const List<String> _legacyKeys = [
    'channel_labels',
    'load_cell_bank',
    'channel_load_cells',
    'measured_excitation_mv',
  ];

  final SharedPreferences _prefs;

  // mV/V is the default: it converts with board calibration alone, so a
  // fresh install shows meaningful numbers before any load cell is assigned
  // (force units need per-channel load-cell profiles).
  DisplayUnit _displayUnit = DisplayUnit.mVv;
  DisplayUnit get displayUnit => _displayUnit;

  /// Which channels are shown in the live view. Local to the live tab —
  /// each recorded session carries its own visibility set.
  List<bool> _activeChannels = List.filled(nwNumAdcChan, true);
  List<bool> get activeChannels => List.unmodifiable(_activeChannels);

  List<int> get activeChannelIndices => [
    for (int i = 0; i < _activeChannels.length; i++)
      if (_activeChannels[i]) i,
  ];

  bool _wakelockEnabled = false;
  bool get wakelockEnabled => _wakelockEnabled;

  double _lcWarnFraction = defaultLcWarnFraction;
  double get lcWarnFraction => _lcWarnFraction;

  /// Master switch for all limit indication: the chart's limit markers,
  /// dashes and zone shading, the live numbers' status icons, and the clip
  /// latch. When off, the graphs and numbers show no limit-related chrome.
  bool _limitWarningsEnabled = true;
  bool get limitWarningsEnabled => _limitWarningsEnabled;

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

  Future<void> setLcWarnFraction(double fraction) async {
    _lcWarnFraction = fraction.clamp(
      minLcWarnFraction,
      maxLcWarnFraction,
    );
    notifyListeners();
    await _prefs.setDouble(_keyLcWarnFraction, _lcWarnFraction);
  }

  Future<void> setLimitWarningsEnabled(bool enabled) async {
    _limitWarningsEnabled = enabled;
    notifyListeners();
    await _prefs.setBool(_keyLimitWarnings, enabled);
  }
}
