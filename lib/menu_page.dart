import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' show Provider;

import 'about_page.dart' show AboutPage;
import 'user_page.dart' show UserPage;
import 'connect_page.dart' show ConnectPage;
import 'graph_page.dart' show GraphPage;
import 'history_page.dart' show HistoryPage;
import 'user_provider.dart' show UserProvider;

class MenuPage extends StatelessWidget {
  const MenuPage({super.key});

  @override
  Widget build(BuildContext context) {
    final userProvider = Provider.of<UserProvider>(context);

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('User: ${userProvider.getSelectedUser().name}'),
            _buildMenuButton(context, 'User', UserPage()),
            _buildMenuButton(context, 'Connect', const ConnectPage()),
            _buildMenuButton(context, 'Session', const GraphPage()),
            _buildMenuButton(context, 'History', const HistoryPage()),
            _buildMenuButton(context, 'About', const AboutPage()),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuButton(BuildContext context, String text, Widget page) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.tonal(
          onPressed: () => unawaited(Navigator.push(
              context, MaterialPageRoute(builder: (context) => page))),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(text),
          ),
        ),
      ),
    );
  }
}
