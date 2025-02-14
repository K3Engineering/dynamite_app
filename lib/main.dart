import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'menu_page.dart';
import 'user_page.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => UserProvider(),
      child: DynoApp(),
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
        appBarTheme: AppBarTheme(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            side: BorderSide(
              width: 2.0,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: const BorderRadius.all(
              Radius.circular(30.0),
            ),
          ),
        ),
        useMaterial3: true,
      ),
      home: const MenuPage(),
    );
  }
}
