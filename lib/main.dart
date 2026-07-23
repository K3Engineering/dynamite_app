import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/app_settings.dart';
import 'services/adc_packet_decoder.dart';
import 'services/app_events.dart';
import 'services/ble_link_manager.dart';
import 'services/data_hub.dart';
import 'services/database.dart';
// Debug-only hot-restart hook: on web, BLE notification listeners and timers
// survive a hot restart, so each generation registers a cleanup that the next
// generation runs first thing in main(). No-op stub on native platforms.
import 'services/hot_restart_cleanup_stub.dart'
    if (dart.library.js_interop) 'services/hot_restart_cleanup_web.dart';
import 'services/recording_controller.dart';
import 'services/session_storage.dart';
import 'screens/app_shell.dart';
import 'widgets/status_colors.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Silence and tear down the previous hot-restart generation's BLE link
  // (web debug only) BEFORE anything else, so its stale notification stream
  // stops spamming the disposed engine view and its GATT connection is
  // released for us to reconnect. Runs before session recovery so a recording
  // interrupted by the restart is finalized by the recovery pass below.
  runPreviousHotRestartCleanup();
  // Repair any sessions left incomplete by a crash before the UI reads the
  // session list, so partial sessions are finalized (or pruned) first.
  await SessionStorage.recoverIncompleteSessions();

  // Object graph, one layer per concern:
  //   BleLinkManager (link state machine) --raw bytes--> AdcPacketDecoder
  //   (wire protocol) --decoded samples--> DataHub (storage + stats)
  //   <--observed by-- RecordingController (session lifecycle + persistence).
  // AppEvents is the one-shot notice bus: producers emit, AppShell consumes.
  final appEvents = AppEvents();
  final dataHub = DataHub();
  final decoder = AdcPacketDecoder(dataHub);
  final linkManager = BleLinkManager(events: appEvents)
    ..onAdcData = decoder.onDataPacket
    ..onCalibrationData = decoder.onCalibrationPacket;
  final recording = RecordingController(
    dataHub: dataHub,
    linkManager: linkManager,
    decoder: decoder,
    events: appEvents,
  );
  final appSettings = AppSettings();
  // Push per-channel load-cell assignments into the data layer now and on
  // every settings change (the async prefs load notifies when it resolves).
  // Content-equal pushes are a no-op inside the hub.
  dataHub.updateLoadCells(appSettings.channelLoadCells);
  appSettings.addListener(
    () => dataHub.updateLoadCells(appSettings.channelLoadCells),
  );

  // Hand the NEXT hot-restart generation a way to tear this one down (web
  // debug only). Fire-and-forget: the callbacks are silenced synchronously
  // inside shutdownForHotRestart; the GATT disconnect completes async.
  registerHotRestartCleanup(() {
    unawaited(linkManager.shutdownForHotRestart());
    // Close the DB too, so the next generation re-opens it and migrations
    // run against the current schemaVersion — otherwise the old open
    // connection survives the restart and a bumped schema never applies.
    unawaited(AppDatabase.closeInstance());
  });
  // Layer 2 (web debug only): the engine view is disposed by
  // `ext.flutter.disassemble` BEFORE the new generation boots, so packets
  // arriving during module reload would spam "disposed EngineFlutterView"
  // assertions. The filter catches the first one in THIS (soon-to-be-stale)
  // generation, silences the feed immediately, and swallows the spam.
  installHotRestartErrorFilter(() {
    unawaited(linkManager.shutdownForHotRestart());
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appSettings),
        // App-lifetime singletons created above (never disposed — the app
        // root never unmounts), provided individually so each screen depends
        // only on the layer it actually uses.
        Provider.value(value: appEvents),
        ChangeNotifierProvider.value(value: dataHub),
        ChangeNotifierProvider.value(value: linkManager),
        ChangeNotifierProvider.value(value: recording),
      ],
      child: const DynoApp(),
    ),
  );
}

class DynoApp extends StatelessWidget {
  const DynoApp({super.key});

  @override
  Widget build(BuildContext context) {
    // NOTE on color roles: these schemes use the M2-era ColorScheme.light() /
    // .dark() constructors, whose M3 roles silently fall back to the base
    // roles when unspecified (e.g. primaryContainer -> primary; see the SDK
    // getters in color_scheme.dart). The container pairs below are declared
    // explicitly so the surface/content contract the app already relies on —
    // dark-blue "connected" surfaces with white content — lives here instead
    // of hiding in fallback behavior.
    const lightScheme = ColorScheme.light(
      // top "connected" bar, rec, tare buttons, button fonts
      primary: Color(0xFF455A64),
      onPrimary: Colors.white,
      // Connected/highlighted surfaces (Live banner, active device row).
      primaryContainer: Color(0xFF455A64),
      onPrimaryContainer: Colors.white,
      // active tab on the bottom
      secondary: Color(0xFF455A64),
      // icon color of selected tab
      onSecondary: Colors.white,
      tertiary: Color.fromARGB(255, 211, 47, 47),
      onTertiary: Colors.white,
      surface: Colors.white,
      // text
      onSurface: Color.fromARGB(255, 58, 34, 34),
    );
    const darkScheme = ColorScheme.dark(
      primary: Color.fromARGB(255, 103, 155, 179),
      onPrimary: Colors.white,
      // Same explicit pair as light. Note: white on this light-blue container
      // is mediocre contrast — kept to preserve the existing dark look.
      primaryContainer: Color.fromARGB(255, 103, 155, 179),
      onPrimaryContainer: Colors.white,
      secondary: Color.fromARGB(255, 137, 178, 197),
      onSecondary: Colors.black,
      tertiary: Color(0xFFEF5350),
      onTertiary: Color.fromARGB(255, 255, 55, 55),
      surface: Color(0xFF1E1E1E),
      onSurface: Colors.white,
    );

    // A selected ListTile is the app's highlighted/active row (the connected
    // device on the Devices tab), sitting on a primaryContainer surface. The
    // theme supplies the matching content color — title, subtitle, icons, and
    // IconButtons are all themed by the selected tile — while the surface
    // owner (the Card) supplies the background. selectedTileColor is
    // deliberately NOT set here: painting surfaces is the Card's job.
    ListTileThemeData selectedTileTheme(ColorScheme scheme) =>
        ListTileThemeData(selectedColor: scheme.onPrimaryContainer);

    return MaterialApp(
      title: 'Dynamite',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF8F9FA),
        extensions: const [StatusColors.light],
        colorScheme: lightScheme,
        listTileTheme: selectedTileTheme(lightScheme),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF121212),
        extensions: const [StatusColors.dark],
        colorScheme: darkScheme,
        listTileTheme: selectedTileTheme(darkScheme),
      ),
      home: const AppShell(),
    );
  }
}
