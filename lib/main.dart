import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/app_settings.dart';
import 'services/bt_handling.dart';
import 'services/session_storage.dart';
import 'screens/app_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Repair any sessions left incomplete by a crash before the UI reads the
  // session list, so partial sessions are finalized (or pruned) first.
  await SessionStorage.recoverIncompleteSessions();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettings()),
        ChangeNotifierProvider(create: (_) => BluetoothHandling()),
      ],
      child: const DynoApp(),
    ),
  );
}

class DynoApp extends StatelessWidget {
  const DynoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dynamite',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF8F9FA),
        colorScheme: const ColorScheme.light(
          // top "connected" bar, rec, tare buttons, button fonts
          primary: Color(0xFF455A64),
          onPrimary: Colors.white,
          // active tab on the bottom
          secondary: Color(0xFF455A64),
          // icon color of selected tab
          onSecondary: Colors.white,
          tertiary: Color.fromARGB(255, 211, 47, 47),
          onTertiary: Colors.white,
          surface: Colors.white,
          // text
          onSurface: Color.fromARGB(255, 58, 34, 34),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Color.fromARGB(255, 103, 155, 179),
          onPrimary: Colors.white,
          secondary: Color.fromARGB(255, 137, 178, 197),
          onSecondary: Colors.black,
          tertiary: Color(0xFFEF5350),
          onTertiary: Color.fromARGB(255, 255, 55, 55),
          surface: Color(0xFF1E1E1E),
          onSurface: Colors.white,
        ),
      ),
      home: const AppShell(),
    );
  }
}
