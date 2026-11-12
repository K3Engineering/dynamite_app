import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'models/app_meta.dart';
import 'services/app_settings.dart';
import 'services/adc_packet_decoder.dart';
import 'services/app_events.dart';
import 'services/ble_link_manager.dart';
import 'services/data_hub.dart';
import 'services/demo_device.dart';
import 'services/derived_channels.dart';
import 'services/feed_health_tracker.dart';
import 'services/firmware_catalog.dart';
import 'services/firmware_update_service.dart';
// Debug-only hot-restart hook: web BLE listeners and timers survive a hot
// restart, so each generation registers a cleanup the next one runs first.
import 'services/hot_restart_cleanup_stub.dart'
    if (dart.library.js_interop) 'services/hot_restart_cleanup_web.dart';
import 'services/monitor_pause.dart';
import 'services/recording_controller.dart';
import 'services/rig_state.dart';
import 'services/rig_link_guard.dart';
import 'services/session_files.dart';
import 'services/session_metadata.dart';
import 'services/stream_reset_coordinator.dart';
import 'services/wakelock_policy.dart';
import 'screens/app_shell.dart';

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
  // The monitoring pause (see MonitorPause): decoder-side packet gate, wired
  // before the decoder so the gate closure exists at first packet.
  final monitorPause = MonitorPause(dataHub);
  // The rig's math-channel profile (plate sum/axes/error, or none — see
  // `derived_channel.dart`), pushed on every config change.
  dataHub.updateMathProfile(DerivedChannels.instance.profile);
  DerivedChannels.instance.addListener(
    () => dataHub.updateMathProfile(DerivedChannels.instance.profile),
  );
  final decoder = AdcPacketDecoder(
    dataHub,
    isPaused: () => monitorPause.paused,
  );
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
    pauseChanges: monitorPause,
    pausedNow: () => monitorPause.paused,
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
        ChangeNotifierProvider.value(value: monitorPause),
        ChangeNotifierProvider.value(value: rigState),
        ChangeNotifierProvider.value(value: recording),
        ChangeNotifierProvider.value(value: firmwareUpdates),
      ],
      child: const DynoApp(),
    ),
  );
}

class _FatalErrorWidget extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF202124),
    child: Directionality(
      textDirection: .ltr,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Application error\nRestart Dynamite',
            textAlign: .center,
            style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 18),
          ),
        ),
      ),
    ),
  );
}

class DynoApp extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dynamite Sampler App',
      themeMode: .system,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: const AppShell(),
    );
  }
}
