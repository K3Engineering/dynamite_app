import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'force_unit.dart';

/// Application-wide settings, persisted via SharedPreferences.
class AppSettings extends ChangeNotifier {
  static const String _keyUnit = 'display_unit';
  static const String _keyUserName = 'user_name';
  static const String _keyChannelLabels = 'channel_labels';
  static const String _keyActiveChannels = 'active_channels';

  ForceUnit _displayUnit = ForceUnit.kN;
  ForceUnit get displayUnit => _displayUnit;

  String _userName = '';
  String get userName => _userName;

  /// Labels for each of the 4 ADC channels.
  List<String> _channelLabels = ['Load Cell 1', 'Load Cell 2', 'Ch 3', 'Ch 4'];
  List<String> get channelLabels => List.unmodifiable(_channelLabels);

  /// Which channels are active (shown in live view and recorded).
  List<bool> _activeChannels = [true, true, false, false];
  List<bool> get activeChannels => List.unmodifiable(_activeChannels);

  /// Number of currently active channels.
  int get activeChannelCount => _activeChannels.where((c) => c).length;

  /// Indices of active channels.
  List<int> get activeChannelIndices => [
    for (int i = 0; i < _activeChannels.length; i++)
      if (_activeChannels[i]) i,
  ];

  AppSettings() {
    unawaited(_load());
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();

    final unitName = prefs.getString(_keyUnit);
    if (unitName != null) {
      _displayUnit = ForceUnit.values.firstWhere(
        (u) => u.name == unitName,
        orElse: () => ForceUnit.kN,
      );
    }

    _userName = prefs.getString(_keyUserName) ?? '';

    final labels = prefs.getStringList(_keyChannelLabels);
    if (labels != null && labels.length == 4) {
      _channelLabels = labels;
    }

    final active = prefs.getStringList(_keyActiveChannels);
    if (active != null && active.length == 4) {
      _activeChannels = active.map((s) => s == 'true').toList();
    }

    notifyListeners();
  }

  Future<void> setDisplayUnit(ForceUnit unit) async {
    _displayUnit = unit;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUnit, unit.name);
  }

  Future<void> setUserName(String name) async {
    _userName = name;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUserName, name);
  }

  Future<void> setChannelLabel(int index, String label) async {
    _channelLabels[index] = label;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyChannelLabels, _channelLabels);
  }

  Future<void> setChannelActive(int index, bool active) async {
    _activeChannels[index] = active;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyActiveChannels,
      _activeChannels.map((b) => b.toString()).toList(),
    );
  }
}
