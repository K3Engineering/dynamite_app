import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'user_provider.dart';

class UserPage extends StatelessWidget {
  UserPage({super.key});

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _ageController = TextEditingController();

  @override
  Widget build(final BuildContext context) {
    final userProvider = Provider.of<UserProvider>(context);

    return Scaffold(
      floatingActionButton: IconButton(
        onPressed: () {
          Navigator.pop(context);
        },
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startTop,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                hintText: 'Enter your name',
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _ageController,
              decoration: const InputDecoration(
                labelText: 'Enter your age',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 20),
            FilledButton.tonal(
              onPressed: () {
                final name = _nameController.text;
                final age = int.parse(_ageController.text);
                unawaited(userProvider.storeUserData(name, age));
              },
              child: const Text('Store User Data'),
            ),
            const SizedBox(height: 60),
            DropdownMenu<String>(
              hintText: 'Select a user',
              initialSelection: userProvider.selectedUserName,
              onSelected: userProvider.selectUser,
              dropdownMenuEntries: userProvider.userList.map((user) {
                return DropdownMenuEntry<String>(
                  value: user.name,
                  label: user.name,
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            Text(
              ((DynoUser user) {
                return 'User: ${user.name}, ${user.age} yo.';
              })(userProvider.getSelectedUser()),
              style: const TextStyle(fontSize: 18),
            ),
          ],
        ),
      ),
    );
  }
}
