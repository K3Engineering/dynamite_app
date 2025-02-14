import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'user_provider.dart';

class UserPage extends StatelessWidget {
  UserPage({super.key});

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _ageController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final userProvider = Provider.of<UserProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'User: ${userProvider.selectedUserName ?? 'None'}',
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: <Widget>[
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                hintText: 'Enter your name',
              ),
            ),
            SizedBox(height: 4),
            TextField(
              controller: _ageController,
              decoration: const InputDecoration(
                labelText: 'Enter your age',
              ),
              keyboardType: TextInputType.number,
            ),
            SizedBox(height: 20),
            FilledButton.tonal(
              onPressed: () {
                final name = _nameController.text;
                final age = int.parse(_ageController.text);
                userProvider.storeUserData(name, age);
              },
              child: Text('Store User Data'),
            ),
            SizedBox(height: 60),
            DropdownMenu<String>(
              hintText: 'Select a user',
              initialSelection: userProvider.selectedUserName,
              onSelected: (newValue) {
                userProvider.selectUser(newValue);
              },
              dropdownMenuEntries: userProvider.userList.map((user) {
                return DropdownMenuEntry<String>(
                  value: user.name,
                  label: user.name,
                );
              }).toList(),
            ),
            SizedBox(height: 20),
            Text(
              ((user) {
                return 'User: ${user.name}, ${user.age} yo.';
              })(userProvider.getSelectedUser()),
              style: TextStyle(fontSize: 18),
            ),
          ],
        ),
      ),
    );
  }
}
