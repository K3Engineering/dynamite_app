import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/feed_health.dart';
import 'ble_link_manager.dart';
import 'data_hub.dart';

/// The shared 1 Hz feed-health derivation (see [deriveFeedHealth]), one
/// owner for every surface that wants the live classification — the Devices
/// row's chip and the Live tab's banner/stats. [health] is null when the
/// link is not streaming (no live trace to assess), changing edge-only.
///
/// The ticker (not hub notifications) drives recompute: a silent feed
/// produces no packets, so nothing else would refresh the classification.
class FeedHealthTracker {
  FeedHealthTracker({required DataHub hub, required BleLinkManager link})
    : _hub = hub,
      _link = link {
    _link.addListener(_onLinkChanged);
  }

  final DataHub _hub;
  final BleLinkManager _link;

  final ValueNotifier<FeedHealth?> health = ValueNotifier(null);
  Timer? _timer;

  /// Start/stop the ticker on streaming edges. The link manager notifies
  /// for many reasons (RSSI polls included); the edge guard keeps this a
  /// no-op unless streaming actually flipped.
  void _onLinkChanged() {
    final streaming = _link.isStreaming;
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
}
