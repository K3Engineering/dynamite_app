import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/feed_health.dart';
import '../models/hub_event.dart';
import '../utils/edge_watcher.dart';

/// The shared 1 Hz feed-health derivation (see [deriveFeedHealth]): one owner
/// for every surface wanting the live classification (the Devices row's chip,
/// the Live tab's banner/stats). [health] is null when not streaming and
/// changes edge-only.
///
/// The ticker drives recompute — a silent feed produces no packets, so nothing
/// else would refresh it. [HubCleared] forces one too: a new stream reset all
/// the inputs, and waiting a tick would flash the old stream's verdict at
/// connect (the tracker and the reset coordinator react to the same edge,
/// either order).
class FeedHealthTracker {
  FeedHealthTracker({
    required FeedHealthSource hub,
    required Listenable streamingChanges,
    required bool Function() streamingNow,
  }) : _hub = hub {
    _hub.addEventListener(_onHubEvent);
    _watcher = EdgeWatcher<bool>(
      sources: [streamingChanges],
      now: streamingNow,
      // Seeded "not streaming": a tracker built mid-stream starts the
      // ticker on the first notification, as its old timer-null guard did.
      seed: false,
      effect: _onStreamingEdge,
    );
  }

  /// The tracker's narrow read port onto the hub (main wires it in as
  /// [FeedHealthSource]): polled, so it needs no notify side, and it can't
  /// reach the hub's command surface.
  final FeedHealthSource _hub;

  late final EdgeWatcher<bool> _watcher;

  final ValueNotifier<FeedHealth?> health = ValueNotifier(null);
  Timer? _timer;

  void _onStreamingEdge(bool streaming) {
    if (streaming) {
      // Classify at once, not on the first tick: a null [health] then means
      // exactly "not streaming" — never "streaming, not yet classified".
      _tick();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else {
      _timer?.cancel();
      _timer = null;
      health.value = null;
    }
  }

  void _onHubEvent(HubEvent event) {
    // Only HubCleared matters (see the class comment): batch appends are
    // covered by lastDataAt on the next tick, at 1 Hz resolution.
    if (event is HubCleared && _timer != null) _tick();
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
    _watcher.dispose();
    _hub.removeEventListener(_onHubEvent);
    health.dispose();
  }
}
