import 'package:flutter/material.dart';

import 'live_tab.dart';
import 'sessions_tab.dart';
import 'devices_tab.dart';
import 'settings_tab.dart';

/// Root scaffold with bottom navigation tabs.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell> {
  int _currentIndex = 0;

  static const _tabs = [
    _TabDef(icon: Icons.show_chart, label: 'Live'),
    _TabDef(icon: Icons.folder_open, label: 'Sessions'),
    _TabDef(icon: Icons.bluetooth, label: 'Devices'),
    _TabDef(icon: Icons.settings, label: 'Settings'),
  ];

  /// Navigate to a specific tab programmatically (e.g. from status bar tap).
  void switchToTab(int index) {
    if (index >= 0 && index < _tabs.length) {
      setState(() => _currentIndex = index);
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
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
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
