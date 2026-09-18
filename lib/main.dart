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
// Debug-only hot-restart hook: on web, BLE notification listeners and timers
// survive a hot restart, so each generation registers a cleanup that the next
// generation runs first thing in main(). No-op stub on native platforms.
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
  late final BleLinkManager linkManager;
  final rigState = RigState(
    backend: () => linkManager.backend,
    connectedDeviceName: () => linkManager.connectedDeviceName,
    prefs: prefs,
  );
  // The device id/name are read off the link at delivery time (the read
  // only ever runs against the active link).
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
  // A link loss (of any flavor) ends the rig session: the flash document and
  // any unsaved edits die with the connection. A dirty discard is surfaced.
  RigLinkGuard(
    rig: rigState,
    events: appEvents,
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
  // Release checks + the once-per-link update banner; also carries the
  // flash keep-awake hold for the wakelock policy below.
  final firmwareUpdates = FirmwareUpdateService(
    prefs: prefs,
    link: linkManager,
    events: appEvents,
    catalog: GithubReleaseCatalog(),
  );
  // Keep the screen awake while a device stream is live and the setting is
  // on — and unconditionally during an OTA flash (which unsubscribes the
  // feed). Nothing reads this; it exists to react. Construction is the
  // wiring.
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
    // The M2-era ColorScheme.light()/.dark() constructors fall undeclared
    // M3 roles back to base roles (surfaceContainer* -> surface, outline and
    // friends -> onSurface, inverseSurface -> onSurface), which used to theme
    // widgets with the wrong color (a white-on-white dark toast; dividers in
    // full onSurface). We try to declare every role the app reads explicitly.
    // Design language: dark brown is the action accent — everything
    // pressable (buttons, unselected tabs, off-state toggles, chips).
    // Slate is the state color — selected tabs, the connected stripe,
    // on-state toggles, status tokens. Red stays reserved for
    // recording/destructive. The two roles never mix surfaces: brown
    // never sits on slate.
    const lightScheme = ColorScheme.light(
      // Pressable: rec, tare, connect, save, unselected tabs, chips.
      primary: Color(0xFF5D4037),
      onPrimary: Colors.white,
      // Read-only state/status surfaces (connected stripe, status tokens).
      primaryContainer: Color(0xFF455A64),
      onPrimaryContainer: Colors.white,
      // active tab on the bottom
      secondary: Color(0xFF455A64),
      // icon color of selected tab
      onSecondary: Colors.white,
      // This design has no separate tonal container: M3 widgets themed off
      // this role (nav selection pills, selected chips/segments) keep the
      // primary-family look. Declared explicitly (= secondary) rather than
      // left to the light() constructor's identical fallback. Quiet tracks
      // (progress bars) take their own color at the widget: a distinct
      // secondaryContainer here breaks the determinate bar the other way —
      // track identical to the fill, a permanently "full" bar.
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
      // Pressable accent; light brown so black text rides on the fill.
      primary: Color(0xFFA1887F),
      onPrimary: Colors.black,
      // Same explicit pair as light. Note: white on this light-blue container
      // is mediocre contrast — kept to preserve the existing dark look.
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

    // The navigation destinations are pressable until selected, so inactive
    // destinations take the action accent and the selected one takes the
    // state color (white on the slate indicator). Size/weight/spacing
    // replicate the M3 defaults; this theme property replaces the whole
    // resolve, color included.
    NavigationBarThemeData navBarTheme(ColorScheme colors) =>
        NavigationBarThemeData(
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              size: 24,
              color: states.contains(WidgetState.disabled)
                  ? colors.onSurfaceVariant.withValues(alpha: 0.38)
                  : states.contains(WidgetState.selected)
                  ? colors.onSecondaryContainer
                  : colors.primary,
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
                  : colors.primary,
            ),
          ),
        );

    NavigationRailThemeData navRailTheme(ColorScheme colors) =>
        NavigationRailThemeData(
          indicatorColor: colors.secondaryContainer,
          selectedIconTheme: IconThemeData(color: colors.onSecondaryContainer),
          unselectedIconTheme: IconThemeData(color: colors.primary),
          selectedLabelTextStyle: TextStyle(color: colors.onSurface),
          unselectedLabelTextStyle: TextStyle(color: colors.primary),
        );

    // On-state toggles are state, not action: slate track, not the action
    // accent the M3 defaults would draw off `primary`.
    SwitchThemeData switchTheme(ColorScheme colors) => SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.secondary
            : colors.surfaceContainerHighest,
      ),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.onSecondary
            : colors.outline,
      ),
    );

    // Unselected chips are pressable (action accent); selected chips are
    // state (slate fill, matching the M3 secondaryContainer default).
    ChipThemeData chipTheme(ColorScheme colors) => ChipThemeData(
      selectedColor: colors.secondaryContainer,
      labelStyle: TextStyle(color: colors.primary),
      secondaryLabelStyle: TextStyle(color: colors.onSecondaryContainer),
    );

    // Same split as chips: the chosen segment is state, the others pressable.
    SegmentedButtonThemeData segmentedTheme(ColorScheme colors) =>
        SegmentedButtonThemeData(
          style: ButtonStyle(
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return colors.onSurfaceVariant.withValues(alpha: 0.38);
              }
              return states.contains(WidgetState.selected)
                  ? colors.onSecondaryContainer
                  : colors.primary;
            }),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? colors.secondaryContainer
                  : null,
            ),
          ),
        );

    return MaterialApp(
      title: 'Dynamite Sampler App',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF8F9FA),
        extensions: const [StatusColors.light],
        colorScheme: lightScheme,
        navigationBarTheme: navBarTheme(lightScheme),
        navigationRailTheme: navRailTheme(lightScheme),
        switchTheme: switchTheme(lightScheme),
        chipTheme: chipTheme(lightScheme),
        segmentedButtonTheme: segmentedTheme(lightScheme),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF121212),
        extensions: const [StatusColors.dark],
        colorScheme: darkScheme,
        navigationBarTheme: navBarTheme(darkScheme),
        navigationRailTheme: navRailTheme(darkScheme),
        switchTheme: switchTheme(darkScheme),
        chipTheme: chipTheme(darkScheme),
        segmentedButtonTheme: segmentedTheme(darkScheme),
      ),
      home: const AppShell(),
    );
  }
}
