import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/derived_channel.dart';
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

    // The stored list spans the channel id space (hardware + derived);
    // shorter lists from before derived channels existed pad on (the new
    // channels default to active so the rig's channels just appear).
    final active = _prefs.getStringList(_keyActiveChannels);
    if (active != null &&
        active.length >= kAdcChannelCount &&
        active.length <= kMaxChannelCount) {
      for (int i = 0; i < active.length; i++) {
        _activeChannels[i] = active[i] == 'true';
      }
    }

    _wakelockEnabled = _prefs.getBool(_keyWakelock) ?? false;

    _showDebugLiveValues = _prefs.getBool(_keyDebugLiveValues) ?? false;

    _channelFamily = switch (_prefs.getString(_keyChannelFamily)) {
      final name? =>
        ChannelFamily.values.asNameMap()[name] ?? ChannelFamily.all,
      null => ChannelFamily.all,
    };
  }

  static const String _keyUnit = 'display_unit';
  static const String _keyActiveChannels = 'active_channels';
  static const String _keyWakelock = 'wakelock_enabled';
  static const String _keyDebugLiveValues = 'debug_live_values';
  static const String _keyChannelFamily = 'channel_family';

  final SharedPreferences _prefs;

  // mV/V is the default: it converts with board calibration alone, so a
  // fresh install shows meaningful numbers before any load cell is assigned
  // (force units need per-channel load-cell profiles).
  DisplayUnit _displayUnit = DisplayUnit.mVv;
  DisplayUnit get displayUnit => _displayUnit;

  /// Which channels are shown in the live view, in the widened channel id
  /// space (hardware channels then derived). Local to the live tab — each
  /// recorded session carries its own visibility set.
  final List<bool> _activeChannels = List.filled(kMaxChannelCount, true);
  List<bool> get activeChannels => List.unmodifiable(_activeChannels);

  List<int> get activeChannelIndices => [
    for (int i = 0; i < _activeChannels.length; i++)
      if (_activeChannels[i]) i,
  ];

  /// Which slice of the channel id space is on screen (the stats table and
  /// the graphs). Phone-width headers fit one family; see [ChannelFamily].
  ChannelFamily _channelFamily = ChannelFamily.all;
  ChannelFamily get channelFamily => _channelFamily;

  /// [indices] filtered down to the on-screen family.
  List<int> visibleChannelIndices(Iterable<int> indices) => [
    for (final i in indices)
      if (_channelFamily.includes(i)) i,
  ];

  bool _wakelockEnabled = false;
  bool get wakelockEnabled => _wakelockEnabled;

  /// Whether the live view shows the debug-only "AC RMS" stat row.
  bool _showDebugLiveValues = false;
  bool get showDebugLiveValues => _showDebugLiveValues;

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

  Future<void> setShowDebugLiveValues(bool enabled) async {
    _showDebugLiveValues = enabled;
    notifyListeners();
    await _prefs.setBool(_keyDebugLiveValues, enabled);
  }

  Future<void> setChannelFamily(ChannelFamily family) async {
    _channelFamily = family;
    notifyListeners();
    await _prefs.setString(_keyChannelFamily, family.name);
  }
}
