import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/app_settings.dart';
import '../services/app_events.dart';
import '../services/ble_link_manager.dart';
import 'live_tab.dart';
import 'sessions_tab.dart';
import 'devices_tab.dart';
import 'settings_tab.dart';

/// Root scaffold with bottom navigation tabs.
///
/// Also the single consumer of [AppEvents]: one-shot notices from the service
/// layer surface here as SnackBars, so delivery doesn't depend on which tab
/// happens to be mounted or rebuilding.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell> {
  int _currentIndex = 0;
  StreamSubscription<AppEvent>? _eventsSub;

  /// Last wakelock state pushed to the plugin, so [_syncWakelock] only calls
  /// the platform channel on an actual edge (the link manager notifies on
  /// every RSSI poll; enabling repeatedly would be a pointless side effect).
  bool? _wakelockApplied;

  /// App-lifetime singletons driving the wakelock; captured in [initState].
  late final AppSettings _settings = context.read<AppSettings>();
  late final BleLinkManager _link = context.read<BleLinkManager>();

  static const _tabs = [
    _TabDef(icon: Icons.show_chart, label: 'Live'),
    _TabDef(icon: Icons.folder_open, label: 'Sessions'),
    _TabDef(icon: Icons.bluetooth, label: 'Devices'),
    _TabDef(icon: Icons.settings, label: 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    _eventsSub = context.read<AppEvents>().stream.listen(_onAppEvent);
    // Keep the screen awake while a device stream is live and the setting is
    // on. Both inputs are app-lifetime singletons; the listener only reacts
    // to actual edges.
    _settings.addListener(_syncWakelock);
    _link.addListener(_syncWakelock);
    _syncWakelock();
    _onTabActivated(_currentIndex);
  }

  @override
  void dispose() {
    unawaited(_eventsSub?.cancel());
    _settings.removeListener(_syncWakelock);
    _link.removeListener(_syncWakelock);
    super.dispose();
  }

  void _syncWakelock() {
    final target = _settings.wakelockEnabled && _link.isStreaming;
    if (target == _wakelockApplied) return;
    _wakelockApplied = target;
    unawaited(target ? WakelockPlus.enable() : WakelockPlus.disable());
  }

  void _onAppEvent(AppEvent event) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (event) {
      case BleDisconnectTimeout(:final deviceName):
        messenger.showSnackBar(
          SnackBar(content: Text('$deviceName didn\'t disconnect cleanly.')),
        );
      case BleConnectionFailed(:final deviceName):
        messenger.showSnackBar(
          SnackBar(
            content: Text('Lost connection to $deviceName during setup.'),
          ),
        );
      case BleConnectionLost(:final deviceName):
        messenger.showSnackBar(
          SnackBar(content: Text('Connection to $deviceName lost.')),
        );
      case RecordingStorageError(:final error):
        messenger.showSnackBar(
          SnackBar(
            content: Text('Recording stopped — storage error: $error'),
            behavior: SnackBarBehavior.floating,
            persist: true,
            showCloseIcon: true,
          ),
        );
    }
  }

  /// Navigate to a specific tab programmatically (e.g. from status bar tap).
  void switchToTab(int index) {
    if (index < 0 || index >= _tabs.length || index == _currentIndex) return;
    setState(() => _currentIndex = index);
    _onTabActivated(index);
  }

  /// Jump to the Devices tab — the single home of the Devices tab index for
  /// every "connect a device" prompt across the app.
  void goToDevices() => switchToTab(2);

  /// Tab-activation side effects, driven from here (the owner of the tab
  /// index) so the tabs themselves stay stateless:
  ///  * Devices tab visible: prompt to enable Bluetooth, and start RSSI
  ///    polling (RSSI is only displayed there — don't poll off-screen).
  void _onTabActivated(int index) {
    final devicesVisible = index == 2;
    _link.setRssiUiActive(devicesVisible);
    if (devicesVisible) {
      unawaited(_link.requestEnableBluetooth());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [LiveTab(), SessionsTab(), DevicesTab(), SettingsTab()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: switchToTab,
        destinations: [
          for (final tab in _tabs)
            NavigationDestination(icon: Icon(tab.icon), label: tab.label),
        ],
      ),
    );
  }
}

class _TabDef {
  const _TabDef({required this.icon, required this.label});
  final IconData icon;
  final String label;
}
