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
import 'services/firmware_catalog.dart';
import 'services/firmware_update_service.dart';
// Debug-only hot-restart hook: web BLE listeners and timers survive a hot
// restart, so each generation registers a cleanup the next one runs first.
import 'services/hot_restart_cleanup_stub.dart'
    if (dart.library.js_interop) 'services/hot_restart_cleanup_web.dart';
import 'services/recording_controller.dart';
import 'services/rig_state.dart';
import 'services/rig_link_guard.dart';
import 'services/session_files.dart';
import 'services/session_metadata.dart';
import 'services/stream_reset_coordinator.dart';
import 'services/wakelock_policy.dart';
import 'screens/app_shell.dart';
import 'status_colors.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kReleaseMode) ErrorWidget.builder = (_) => const _FatalErrorWidget();
  // Tear down the previous hot-restart generation's BLE link first, so its
  // stale notifications stop and its GATT connection is released.
  runPreviousHotRestartCleanup();
  // The web primary-tab gate lives in web/flutter_bootstrap.js: a losing
  // tab never boots the engine, so main() only ever runs in the tab that
  // holds the lock.
  // Minimal cleanup registered now, replaced by the full teardown below: a
  // restart in the startup window would otherwise leave the dying generation's
  // session-file handles open.
  registerHotRestartCleanup(terminateSessionSinkWorker);
  final appEvents = AppEvents();
  // Session storage installs lazily: an interrupted-on-crash recording just
  // lists as such (no recovery pass), and a store that can't open fails loudly
  // at the first op that touches it.
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
  late final BleLinkManager linkManager;
  final rigState = RigState(
    backend: () => linkManager.backend,
    connectedDeviceName: () => linkManager.connectedDeviceName,
    prefs: prefs,
    events: appEvents,
  );
  // Read off the link at delivery time, against the active link.
  linkManager = BleLinkManager(
    events: appEvents,
    demo: DemoDevice(),
    onAdcData: decoder.onDataPacket,
    onSampleRate: dataHub.setSampleRate,
    onDeviceFlash: (flash) {
      dataHub.updateBoardCalibration(flash.board);
      rigState.onFlashRead(
        linkManager.connectedDeviceId,
        linkManager.connectedDeviceName,
        flash,
      );
    },
  );
  final feedHealth = FeedHealthTracker(
    hub: dataHub,
    streamingChanges: linkManager,
    streamingNow: () => linkManager.isStreaming,
  );
  // A link loss ends the rig session; a dirty discard is surfaced.
  RigLinkGuard(
    rig: rigState,
    linkChanges: linkManager,
    linkUpNow: () => linkManager.isLinkUp,
  );
  // New-stream clears and calibration forgetting on link transitions.
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
      // Non-null at session start: recording requires a streaming link, and
      // streaming implies the connect-time DIS read succeeded.
      info: linkManager.connectedDeviceInfo!,
    ),
    deviceKvsSnapshot: () => rigState.kvsSnapshot,
    onSessionBoundary: decoder.resetContinuity,
    events: appEvents,
  );
  final appSettings = AppSettings(prefs: prefs);
  // Release checks + once-per-link update banner; holds the flash wake lock.
  final firmwareUpdates = FirmwareUpdateService(
    prefs: prefs,
    link: linkManager,
    events: appEvents,
    catalog: GithubReleaseCatalog(),
  );
  // Keep the screen awake while streaming (setting-gated) and during an OTA
  // flash. Nothing reads this; construction is the wiring.
  WakelockPolicy(
    settings: appSettings,
    streamingChanges: linkManager,
    streamingNow: () => linkManager.isStreaming,
    holdChanges: firmwareUpdates.flashInProgress,
    holdNow: () => firmwareUpdates.flashInProgress.value,
  );
  // Content-equal pushes are a no-op inside the hub.
  dataHub.updateLoadCells(rigState.channelCells);
  rigState.addListener(() => dataHub.updateLoadCells(rigState.channelCells));

  // The full teardown for the NEXT generation, replacing the minimal one above.
  // Fire-and-forget: callbacks are silenced synchronously, the GATT disconnect
  // completes async. The sink-worker terminate must precede the new storage
  // opening.
  registerHotRestartCleanup(() {
    unawaited(linkManager.shutdownForHotRestart());
    terminateSessionSinkWorker();
  });
  // The engine view is disposed before the new generation boots; the filter
  // silences the feed on the first "disposed EngineFlutterView" assertion.
  installHotRestartErrorFilter(() {
    unawaited(linkManager.shutdownForHotRestart());
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appSettings),
        Provider.value(value: appMeta),
        // App-lifetime singletons, provided individually so each screen depends
        // only on the layer it uses.
        Provider.value(value: appEvents),
        Provider.value(value: feedHealth),
        ChangeNotifierProvider.value(value: dataHub),
        ChangeNotifierProvider.value(value: linkManager),
        ChangeNotifierProvider.value(value: rigState),
        ChangeNotifierProvider.value(value: recording),
        ChangeNotifierProvider.value(value: firmwareUpdates),
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
    // ColorScheme.light()/.dark() fall undeclared M3 roles back to base roles,
    // theming some widgets wrong; declare every role the app reads.
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
      // Kept primary-family for M3 widgets themed off this role. A distinct
      // secondaryContainer would make determinate progress tracks match their
      // fill.
      secondaryContainer: Color(0xFF455A64),
      onSecondaryContainer: Colors.white,
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
      // White on this container is mediocre contrast; kept for the existing
      // dark look.
      primaryContainer: Color.fromARGB(255, 103, 155, 179),
      onPrimaryContainer: Colors.white,
      secondary: Color.fromARGB(255, 137, 178, 197),
      onSecondary: Colors.black,
      // Same declaration as light (= secondary); see the comment there.
      secondaryContainer: Color.fromARGB(255, 137, 178, 197),
      onSecondaryContainer: Colors.black,
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

    // A selected ListTile supplies the matching content color; the surface
    // owner (the Card) supplies the background, so selectedTileColor is not set
    // here.
    ListTileThemeData selectedTileTheme(ColorScheme scheme) =>
        ListTileThemeData(selectedColor: scheme.onPrimaryContainer);

    // M3's inactive nav color is too quiet; only that moves, to onSurface.
    // Sizes replicate the M3 defaults (this property replaces the whole
    // resolve).
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
