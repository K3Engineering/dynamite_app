import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_settings.dart';

/// Keep-awake policy: the screen stays on while a device stream is live and
/// the user's setting is on. Constructed once in main; listens through the
/// same narrow stream-liveness port shape [StreamResetCoordinator] uses (a
/// notify source plus a poll closure), so it never depends on the link
/// layer's concrete type. Nothing reads this; it exists to react.
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
  }) : _settings = settings,
       _streamingChanges = streamingChanges,
       _streamingNow = streamingNow,
       _holdChanges = holdChanges,
       _holdNow = holdNow {
    _settings.addListener(_sync);
    _streamingChanges.addListener(_sync);
    _holdChanges?.addListener(_sync);
    _sync();
  }

  final AppSettings _settings;
  final Listenable _streamingChanges;
  final bool Function() _streamingNow;
  final Listenable? _holdChanges;
  final bool Function()? _holdNow;

  /// Last state pushed to the plugin, so [_sync] only crosses the platform
  /// channel on an actual edge (the streaming source notifies on every RSSI
  /// poll; enabling repeatedly would be a pointless side effect). Starts at
  /// the platform's boot state, no lock held: otherwise the constructor pass
  /// "disables" an already-idle lock, which on web downloads the plugin's
  /// no_sleep.js for nothing.
  bool _applied = false;

  void _sync() {
    final target =
        (_settings.wakelockEnabled && _streamingNow()) ||
        (_holdNow?.call() ?? false);
    if (target == _applied) return;
    _applied = target;
    unawaited(target ? WakelockPlus.enable() : WakelockPlus.disable());
  }

  void dispose() {
    _settings.removeListener(_sync);
    _streamingChanges.removeListener(_sync);
    _holdChanges?.removeListener(_sync);
  }
}
