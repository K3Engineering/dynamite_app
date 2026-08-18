import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/feed_health.dart';
import 'data_hub.dart';

/// The shared 1 Hz feed-health derivation (see [deriveFeedHealth]), one
/// owner for every surface that wants the live classification — the Devices
/// row's chip and the Live tab's banner/stats. [health] is null when the
/// link is not streaming (no live trace to assess), changing edge-only.
///
/// The ticker (not hub notifications) drives recompute: a silent feed
/// produces no packets, so nothing else would refresh the classification.
class FeedHealthTracker {
  FeedHealthTracker({
    required DataHub hub,
    required Listenable streamingChanges,
    required bool Function() streamingNow,
  }) : _hub = hub,
       _streamingChanges = streamingChanges,
       _streamingNow = streamingNow {
    _streamingChanges.addListener(_onStreamingChanged);
  }

  final DataHub _hub;

  /// Notifies when the link's streaming state may have changed; queried via
  /// [_streamingNow]. The tracker's narrow port onto the link layer — main
  /// wires the link manager in, tests wire their own source.
  final Listenable _streamingChanges;
  final bool Function() _streamingNow;

  final ValueNotifier<FeedHealth?> health = ValueNotifier(null);
  Timer? _timer;

  /// Start/stop the ticker on streaming edges. The source notifies for many
  /// reasons (RSSI polls included); the edge guard keeps this a no-op unless
  /// streaming actually flipped.
  void _onStreamingChanged() {
    final streaming = _streamingNow();
    if (streaming == (_timer != null)) return;
    if (streaming) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else {
      _timer?.cancel();
      _timer = null;
      health.value = null;
    }
  }

  void _tick() {
    final next = deriveFeedHealth(
      streaming: true,
      totalSamples: _hub.totalSamples,
      lastDataAt: _hub.lastDataAt,
      lastMalformedPacketAt: _hub.lastMalformedPacketAt,
      streamStartedAt: _hub.streamStartedAt,
    );
    if (next != health.value) health.value = next;
  }

  /// Cancel the ticker and release [health]. The real instance is
  /// app-lifetime (never disposed); tests dispose theirs so the ticker
  /// can't leak past a widget test's end-of-test timer check.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _streamingChanges.removeListener(_onStreamingChanged);
    health.dispose();
  }
}
