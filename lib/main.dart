import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'menu_page.dart' show MenuPage;
import 'user_provider.dart' show UserProvider;
import 'bt_handling.dart' show BluetoothHandling;

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => UserProvider(),
        ),
        Provider<BluetoothHandling>(
          create: (_) => BluetoothHandling(),
        ),
      ],
      child: const DynoApp(),
    ),
  );
}

class DynoApp extends StatelessWidget {
  const DynoApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dynamite',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            side: BorderSide(
              width: 2,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(
              Radius.circular(30),
            ),
          ),
        ),
        useMaterial3: true,
      ),
      home: const MenuPage(),
    );
  }
}
