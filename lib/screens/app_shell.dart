import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

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
///
/// The tab-index side effect (the Devices-tab visibility poke) lives here
/// because the IndexedStack keeps every tab mounted — tab-local
/// initState/dispose never see visibility changes. The keep-awake policy is
/// application-lifecycle, not navigation: it lives in
/// services/wakelock_policy.dart, wired in main.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell> {
  int _currentIndex = 0;
  StreamSubscription<AppEvent>? _eventsSub;

  /// App-lifetime link manager for the tab-visibility poke; captured in
  /// [initState].
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
    _onTabActivated(_currentIndex);
  }

  @override
  void dispose() {
    unawaited(_eventsSub?.cancel());
    super.dispose();
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
      case RigEditsDiscarded():
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Disconnected — unsaved load cell changes were discarded.',
            ),
          ),
        );
      case CalibrationUnreadable(:final deviceName):
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Could not read calibration from $deviceName — '
              'nominal values in use.',
            ),
          ),
        );
    }
  }

  /// Navigate to a specific tab programmatically (passed to the tabs as
  /// navigation callbacks, e.g. the Live tab's "Connect a device" action).
  void switchToTab(int index) {
    if (index < 0 || index >= _tabs.length || index == _currentIndex) return;
    setState(() => _currentIndex = index);
    _onTabActivated(index);
  }

  /// Jump to the Devices tab.
  void goToDevices() => switchToTab(2);

  /// Jump to the Settings tab.
  void goToSettings() => switchToTab(3);

  /// Tab-activation side effects, driven from here (the owner of the tab
  /// index) so the tabs themselves stay stateless:
  ///  * Devices tab visible: start the on-screen-only device-row freshness
  ///    poke (see [BleLinkManager.setDevicesTabVisible]). RSSI polling is NOT
  ///    started here — it runs for the link's whole streaming lifetime
  ///    regardless of which tab is visible.
  void _onTabActivated(int index) {
    _link.setDevicesTabVisible(index == 2);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          LiveTab(onGoToDevices: goToDevices),
          const SessionsTab(),
          DevicesTab(onGoToSettings: goToSettings),
          SettingsTab(onGoToDevices: goToDevices),
        ],
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
