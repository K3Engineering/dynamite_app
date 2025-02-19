import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' show Provider;

import 'about_page.dart' show AboutPage;
import 'user_page.dart' show UserPage;
import 'graph_page.dart' show GraphPage;
import 'user_provider.dart' show UserProvider;

class MenuPage extends StatelessWidget {
  const MenuPage({super.key});

  @override
  Widget build(BuildContext context) {
    final userProvider = Provider.of<UserProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'User: ${userProvider.selectedUserName ?? 'None'}',
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _buildMenuButton(context, 'User', UserPage()),
            _buildMenuButton(context, 'Graph', const GraphPage()),
            _buildMenuButton(context, 'About', const AboutPage()),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuButton(BuildContext context, String text, Widget page) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.tonal(
          onPressed: () => unawaited(Navigator.push(
              context, MaterialPageRoute(builder: (context) => page))),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(text),
          ),
        ),
      ),
    );
  }
}
