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
  static const String _keyDerivativeChannels = 'derivative_channels';
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

  /// Which channels have their derivative (dF/dt) shown in the live view.
  /// Disabled by default; enabling any one of them reveals the dF/dt chart.
  List<bool> _derivativeChannels = [false, false, false, false];
  List<bool> get derivativeChannels => List.unmodifiable(_derivativeChannels);

  /// Indices of derivative-enabled channels.
  List<int> get derivativeChannelIndices => [
    for (int i = 0; i < _derivativeChannels.length; i++)
      if (_derivativeChannels[i]) i,
  ];

  bool _wakelockEnabled = false;
  bool get wakelockEnabled => _wakelockEnabled;

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

    final labels = prefs.getStringList(_keyChannelLabels);
    if (labels != null && labels.length == nwNumAdcChan) {
      _channelLabels = labels;
    }

    final active = prefs.getStringList(_keyActiveChannels);
    if (active != null && active.length == nwNumAdcChan) {
      _activeChannels = active.map((s) => s == 'true').toList();
    }

    final derivative = prefs.getStringList(_keyDerivativeChannels);
    if (derivative != null && derivative.length == 4) {
      _derivativeChannels = derivative.map((s) => s == 'true').toList();
    }

    _wakelockEnabled = prefs.getBool(_keyWakelock) ?? false;

    notifyListeners();
  }

  Future<void> setDisplayUnit(ForceUnit unit) async {
    _displayUnit = unit;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUnit, unit.name);
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

  Future<void> setDerivativeChannelActive(int index, bool active) async {
    _derivativeChannels[index] = active;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyDerivativeChannels,
      _derivativeChannels.map((b) => b.toString()).toList(),
    );
  }

  Future<void> setWakelockEnabled(bool enabled) async {
    _wakelockEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyWakelock, enabled);
  }
}
