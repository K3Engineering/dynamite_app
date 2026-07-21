import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/adc_protocol.dart';
import 'force_unit.dart';

/// Application-wide settings, persisted via SharedPreferences.
class AppSettings extends ChangeNotifier {
  static const String _keyUnit = 'display_unit';
  static const String _keyChannelLabels = 'channel_labels';
  static const String _keyActiveChannels = 'active_channels';
  static const String _keyWakelock = 'wakelock_enabled';

  ForceUnit _displayUnit = ForceUnit.kN;
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
        orElse: () => ForceUnit.kN,
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
}
