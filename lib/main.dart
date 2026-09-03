import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/app_meta.dart';
import 'services/app_settings.dart';
import 'services/adc_packet_decoder.dart';
import 'services/app_events.dart';
import 'services/ble_link_manager.dart';
import 'services/data_hub.dart';
import 'services/demo_device.dart';
import 'services/feed_health_tracker.dart';
// Debug-only hot-restart hook: on web, BLE notification listeners and timers
// survive a hot restart, so each generation registers a cleanup that the next
// generation runs first thing in main(). No-op stub on native platforms.
import 'services/hot_restart_cleanup_stub.dart'
    if (dart.library.js_interop) 'services/hot_restart_cleanup_web.dart';
import 'services/recording_controller.dart';
import 'services/rig_state.dart';
import 'services/session_files.dart';
import 'services/session_metadata.dart';
import 'services/session_storage.dart';
import 'services/stream_reset_coordinator.dart';
import 'services/wakelock_policy.dart';
import 'screens/app_shell.dart';
import 'status_colors.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kReleaseMode) ErrorWidget.builder = (_) => const _FatalErrorWidget();
  // Silence and tear down the previous hot-restart generation's BLE link
  // (web debug only) BEFORE anything else, so its stale notification stream
  // stops spamming the disposed engine view and its GATT connection is
  // released for us to reconnect.
  runPreviousHotRestartCleanup();
  // The web primary-tab gate lives in web/flutter_bootstrap.js: a losing
  // tab never boots the engine, so main() only ever runs in the tab that
  // holds the lock.
  // Minimal hot-restart cleanup registered immediately (web debug): from
  // here until the full teardown registration below replaces it, the only
  // resource this generation can hold is the sink worker. Without this, a
  // restart landing in the startup window would leave the dying
  // generation's sync access handles on the session files when the new
  // generation's storage opens (only matters mid-recording).
  registerHotRestartCleanup(terminateSessionSinkWorker);
  final appEvents = AppEvents();
  // Session storage installs lazily on first use and needs no startup pass:
  // an interrupted-on-crash recording just lists as such (no recovery, no
  // mutation — see the store's classification), and a store that can't even
  // be opened fails loudly at the first op that touches it.
  // Prefs are resolved here and injected into their owners, so their loads
  // are synchronous constructor work and can never race a user edit.
  // Overlapped: on web the package info is an uncacheable version.json
  // fetch, so awaiting it serially after prefs costs an extra round trip.
  final (prefs, packageInfo) = await (
    SharedPreferences.getInstance(),
    PackageInfo.fromPlatform(),
  ).wait;
  final appMeta = AppMeta(
    version: packageInfo.version,
    buildNumber: packageInfo.buildNumber,
  );

  final dataHub = DataHub();
  final decoder = AdcPacketDecoder(dataHub);
  final linkManager = BleLinkManager(events: appEvents, demo: DemoDevice())
    ..onAdcData = decoder.onDataPacket
    ..onCalibrationData = decoder.onCalibrationPacket
    ..onSampleRate = dataHub.setSampleRate;
  final feedHealth = FeedHealthTracker(
    hub: dataHub,
    streamingChanges: linkManager,
    streamingNow: () => linkManager.isStreaming,
  );
  final rigState = RigState(transport: linkManager, prefs: prefs);
  // The device id/name are read off the link at delivery time (the read
  // only ever runs against the active link).
  decoder.onDeviceFlash = (flash) => rigState.onFlashRead(
    linkManager.connectedDeviceId,
    linkManager.connectedDeviceName,
    flash,
  );
  // A link loss (of any flavor — the getter reads the same '' for all of
  // them) ends the rig session: the flash document and any unsaved edits
  // die with the connection. A dirty discard is surfaced — losing edits
  // silently is exactly the quiet failure this design rejects.
  linkManager.addListener(() {
    if (linkManager.connectedDeviceId.isNotEmpty) return;
    if (rigState.hasPending) appEvents.emit(const RigEditsDiscarded());
    rigState.onLinkDropped();
  });
  // New-stream clears and calibration forgetting on link transitions.
  // Nothing reads this; it exists to react. Construction is the wiring.
  StreamResetCoordinator(
    hub: dataHub,
    streamingChanges: linkManager,
    streamingNow: () => linkManager.isStreaming,
  );
  final recording = RecordingController(
    dataHub: dataHub,
    streamingChanges: linkManager,
    streamingNow: () => linkManager.isStreaming,
    deviceMetadataSnapshot: () => toSessionDeviceMetadata(
      name: linkManager.connectedDeviceName,
      info: linkManager.connectedDeviceInfo,
    ),
    onSessionBoundary: decoder.resetContinuity,
    persistence: const StaticSessionPersistence(),
    events: appEvents,
  );
  final appSettings = AppSettings(prefs: prefs);
  // Keep the screen awake while a device stream is live and the setting is
  // on. Nothing reads this; it exists to react. Construction is the wiring.
  WakelockPolicy(
    settings: appSettings,
    streamingChanges: linkManager,
    streamingNow: () => linkManager.isStreaming,
  );
  // Content-equal pushes are a no-op inside the hub.
  dataHub.updateLoadCells(rigState.channelCells);
  rigState.addListener(() => dataHub.updateLoadCells(rigState.channelCells));

  // Hand the NEXT hot-restart generation a way to tear this one down (web
  // debug only). This full registration replaces the minimal one made at
  // startup. Fire-and-forget: the callbacks are silenced synchronously
  // inside shutdownForHotRestart; the GATT disconnect completes async. The
  // sink worker terminate is synchronous too — its sync access handles lock
  // the session files, so they must die before the new generation's storage
  // opens (only matters mid-recording).
  registerHotRestartCleanup(() {
    unawaited(linkManager.shutdownForHotRestart());
    terminateSessionSinkWorker();
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
        Provider.value(value: appMeta),
        // App-lifetime singletons created above (never disposed — the app
        // root never unmounts), provided individually so each screen depends
        // only on the layer it actually uses.
        Provider.value(value: appEvents),
        Provider.value(value: feedHealth),
        ChangeNotifierProvider.value(value: dataHub),
        ChangeNotifierProvider.value(value: linkManager),
        ChangeNotifierProvider.value(value: rigState),
        ChangeNotifierProvider.value(value: recording),
      ],
      child: const DynoApp(),
    ),
  );
}

class _FatalErrorWidget extends StatelessWidget {
  const _FatalErrorWidget();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF202124),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Application error\nRestart Dynamite',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 18),
          ),
        ),
      ),
    ),
  );
}

class DynoApp extends StatelessWidget {
  const DynoApp({super.key});

  @override
  Widget build(BuildContext context) {
    // The M2-era ColorScheme.light()/.dark() constructors fall undeclared
    // M3 roles back to base roles (surfaceContainer* -> surface, outline and
    // friends -> onSurface, inverseSurface -> onSurface), which used to theme
    // widgets with the wrong color (a white-on-white dark toast; dividers in
    // full onSurface). We try to declare every role the app reads explicitly.
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
      onSurface: Colors.black,
      error: Color(0xFFB00020),
      onError: Colors.white,
      // Dimmed/inactive content (BT-off icon, expired-scan rows).
      outline: Color(0xFF78909C), // blueGrey 400
      // Quiet hairlines; Dividers default to this role in M3.
      outlineVariant: Color(0xFFCFD8DC), // blueGrey 100
      // De-emphasized secondary text (settings notes, plot axis labels).
      onSurfaceVariant: Color(0xFF546E7A), // blueGrey 600
      // De-emphasized surface (the stale device row's card tint):
      // onSurface at 6% blended over surface.
      surfaceContainerHighest: Color(0xFFF0F0F0),
      // SnackBar themes itself off these three; identical in both schemes,
      // so one toast style regardless of mode. Error toasts override
      // background/content via showErrorSnackBar.
      inverseSurface: Color(0xFF323232),
      onInverseSurface: Colors.white,
      inversePrimary: Color(0xFF89B2C5),
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
      onTertiary: Colors.white,
      surface: Color(0xFF1E1E1E),
      onSurface: Colors.white,
      error: Color(0xFFCF6679),
      onError: Colors.black,
      // Dimmed/inactive content (BT-off icon, expired-scan rows).
      outline: Color(0xFF90A4AE), // blueGrey 300
      outlineVariant: Color(0xFF546E7A), // blueGrey 600
      onSurfaceVariant: Color(0xFF78909C), // blueGrey 400
      // De-emphasized surface (the stale device row's card tint):
      // onSurface at 6% blended over surface.
      surfaceContainerHighest: Color(0xFF2B2B2B),
      // Same toast as light.
      inverseSurface: Color(0xFF323232),
      onInverseSurface: Colors.white,
      inversePrimary: Color(0xFF89B2C5),
    );

    // A selected ListTile is the app's highlighted/active row (the connected
    // device on the Devices tab), sitting on a primaryContainer surface. The
    // theme supplies the matching content color — title, subtitle, icons, and
    // IconButtons are all themed by the selected tile — while the surface
    // owner (the Card) supplies the background. selectedTileColor is
    // deliberately NOT set here: painting surfaces is the Card's job.
    ListTileThemeData selectedTileTheme(ColorScheme scheme) =>
        ListTileThemeData(selectedColor: scheme.onPrimaryContainer);

    // M3 styles the navigation bar's inactive destinations at
    // onSurfaceVariant — footnote level, too quiet for the app's primary
    // switching control. Size/weight/spacing replicate the M3 defaults
    // (this theme property replaces the whole resolve, color included);
    // only the inactive color moves, from onSurfaceVariant to
    // near-body-strength onSurface. Playground: 0.7–1.0.
    NavigationBarThemeData navBarTheme(ColorScheme colors) {
      const inactiveAlpha = 0.8;
      return NavigationBarThemeData(
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.disabled)
                ? colors.onSurfaceVariant.withValues(alpha: 0.38)
                : states.contains(WidgetState.selected)
                ? colors.onSecondaryContainer
                : colors.onSurface.withValues(alpha: inactiveAlpha),
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
            color: states.contains(WidgetState.disabled)
                ? colors.onSurfaceVariant.withValues(alpha: 0.38)
                : states.contains(WidgetState.selected)
                ? colors.onSurface
                : colors.onSurface.withValues(alpha: inactiveAlpha),
          ),
        ),
      );
    }

    return MaterialApp(
      title: 'Dynamite Sampler App',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF8F9FA),
        extensions: const [StatusColors.light],
        colorScheme: lightScheme,
        listTileTheme: selectedTileTheme(lightScheme),
        navigationBarTheme: navBarTheme(lightScheme),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF121212),
        extensions: const [StatusColors.dark],
        colorScheme: darkScheme,
        listTileTheme: selectedTileTheme(darkScheme),
        navigationBarTheme: navBarTheme(darkScheme),
      ),
      home: const AppShell(),
    );
  }
}
