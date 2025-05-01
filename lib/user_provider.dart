import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DynoUser {
  static const String _defaultUserName = '';
  final String name;
  final int age;

  DynoUser({required this.name, required this.age});

  @override
  String toString() {
    return '$name:$age';
  }

  static DynoUser fromString(String userString) {
    final parts = userString.split(':');
    return DynoUser(name: parts[0], age: int.parse(parts[1]));
  }
}

class UserProvider with ChangeNotifier {
  List<DynoUser> _userList = [];
  String _selectedUserName = DynoUser._defaultUserName;

  List<DynoUser> get userList => _userList;

  DynoUser getSelectedUser() {
    return _userList.firstWhere(
        (element) => (element.name == _selectedUserName),
        orElse: () => DynoUser(name: DynoUser._defaultUserName, age: 0));
  }

  UserProvider() {
    unawaited(_loadUserList());
  }

  Future<void> storeUserData(String name, int age) async {
    final prefs = await SharedPreferences.getInstance();
    final newUser = DynoUser(name: name, age: age);

    _userList.add(newUser);
    await prefs.setStringList(
        'userList', _userList.map((user) => user.toString()).toList());
    notifyListeners();
  }

  Future<void> _loadUserList() async {
    final prefs = await SharedPreferences.getInstance();
    final storedUserList = prefs.getStringList('userList') ?? [];

    _userList = storedUserList.map(DynoUser.fromString).toList();
    notifyListeners();
  }

  void selectUser(String? userName) {
    _selectedUserName =
        (userName == null) ? DynoUser._defaultUserName : userName;
    notifyListeners();
  }
}
