import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' show Provider;

import 'about_page.dart' show AboutPage;
import 'user_page.dart' show UserPage;
import 'connect_page.dart' show ConnectPage;
import 'history_page.dart' show HistoryPage;
import 'user_provider.dart' show UserProvider;

class MenuPage extends StatelessWidget {
  const MenuPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16 * 2),
        child: Column(
          children: [
            Row(
              children: [
                _buildChangeUserButton(context),
              ],
            ),
            _buildMenuButton(context, 'Session', const ConnectPage()),
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

Widget _buildChangeUserButton(BuildContext context) {
  final UserProvider userProvider = Provider.of<UserProvider>(context);

  return PopupMenuButton<String>(
    initialValue: userProvider.getSelectedUser().name,
    onSelected: (String user) {
      if (user == '+') {
        unawaited(Navigator.push(
            context, MaterialPageRoute(builder: (context) => UserPage())));
      } else {
        userProvider.selectUser(user);
      }
    },
    itemBuilder: (BuildContext context) {
      final List<PopupMenuEntry<String>> list = [];
      for (final user in userProvider.userList) {
        list.add(PopupMenuItem<String>(
          value: user.name,
          child: ListTile(
            title: Text(user.name),
            selected: user == userProvider.getSelectedUser(),
            leading: (user == userProvider.getSelectedUser())
                ? const Icon(Icons.check)
                : null,
          ),
        ));
      }
      list.add(const PopupMenuDivider());
      list.add(const PopupMenuItem<String>(
        value: '+',
        child: ListTile(
          leading: Icon(Icons.add),
          title: Text('New User ...'),
        ),
      ));
      return list;
    },
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryFixed,
        border: Border.all(
          color: Theme.of(context).colorScheme.outline,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'User: ${userProvider.getSelectedUser().name}',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    ),
  );
}

/*
Widget _buildUserButton2(BuildContext context) {
  final UserProvider userProvider = Provider.of<UserProvider>(context);

  return DropdownMenu<String>(
    label: Text(userProvider.getSelectedUser().name),
    onSelected: userProvider.selectUser,
    initialSelection: userProvider.getSelectedUser().name,
    leadingIcon: const Icon(Icons.notes),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
    ),
    textStyle: const TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
    ),
    dropdownMenuEntries: _buildMenuItems2(context),
  );
}

List<DropdownMenuEntry<String>> _buildMenuItems2(BuildContext context) {
  final UserProvider userProvider = Provider.of<UserProvider>(context);

  final List<DropdownMenuEntry<String>> list = [];
  for (final user in userProvider.userList) {
    list.add(
      DropdownMenuEntry<String>(
        value: user.name,
        label: '',
        labelWidget: ListTile(
          title: Text(user.name),
          selected: user == userProvider.getSelectedUser(),
          trailing: (user == userProvider.getSelectedUser())
              ? const Icon(Icons.check)
              : null,
        ),
      ),
    );
  }
  list.add(
    const DropdownMenuEntry<String>(
      value: '',
      label: '',
      labelWidget: Divider(),
    ),
  );
  list.add(
    const DropdownMenuEntry<String>(
      value: '',
      label: '',
      labelWidget: ListTile(
        leading: Icon(Icons.add),
        title: Text('New User ...'),
      ),
    ),
  );
  return list;
}
*/
