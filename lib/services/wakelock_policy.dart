import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../utils/edge_watcher.dart';
import 'app_settings.dart';

/// Keep-awake policy: the screen stays on while a device stream is live and
/// the user's setting is on. Constructed once in main; listens through the
/// same stream-liveness port shape [StreamResetCoordinator] uses (a notify
/// source plus a poll closure), so it never depends on the link layer's
/// concrete type.
class WakelockPolicy {
  WakelockPolicy({
    required AppSettings settings,

    /// Notifies when the stream's liveness may have changed; polled via
    /// [streamingNow]. main wires the link manager in.
    required Listenable streamingChanges,
    required bool Function() streamingNow,

    /// Optional unconditional hold (ignores the user's setting): the OTA
    /// flash hold runs here, since a flash unsubscribes the feed and would
    /// otherwise clear the streaming-based keep-awake mid-transfer.
    Listenable? holdChanges,
    bool Function()? holdNow,
  }) {
    _watcher = EdgeWatcher<bool>(
      sources: [settings, streamingChanges, ?holdChanges],
      now: () =>
          (settings.wakelockEnabled && streamingNow()) ||
          (holdNow?.call() ?? false),
      // Seeded at the platform's boot state (no lock held): otherwise the
      // first check "disables" an already-idle lock, which on web
      // downloads the plugin's no_sleep.js for nothing.
      seed: false,
      effect: (target) =>
          unawaited(target ? WakelockPlus.enable() : WakelockPlus.disable()),
    )..check();
  }

  late final EdgeWatcher<bool> _watcher;

  void dispose() => _watcher.dispose();
}
