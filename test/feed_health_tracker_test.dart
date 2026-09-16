import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/feed_health.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/feed_health_tracker.dart';

/// The tracker and `StreamResetCoordinator` both react to the same
/// streaming edge, and listener order decides which runs first. When the
/// tracker classifies first, it reads the PREVIOUS stream's stamps and can
/// land on a "No data from device"/"Stream stopped" verdict — [HubCleared]
/// must re-derive in the same synchronous dispatch, before any frame shows
/// the stale label for a tick.
void main() {
  late DataHub hub;
  late ValueNotifier<bool> streaming;
  late FeedHealthTracker tracker;

  setUp(() {
    hub = DataHub();
    streaming = ValueNotifier(false);
    tracker = FeedHealthTracker(
      hub: hub,
      streamingChanges: streaming,
      streamingNow: () => streaming.value,
    );
  });

  tearDown(() => tracker.dispose());

  test('a hub reset while streaming re-derives the verdict at once', () {
    // The previous stream's residue, as the hub would hold on connect.
    hub.totalSamples = 0;
    hub.streamStartedAt = DateTime.now().subtract(const Duration(seconds: 30));

    streaming.value = true; // tracker classified before the reset
    expect(tracker.health.value, FeedHealth.silent);

    hub.clear(); // the reset coordinator's counterpart
    expect(tracker.health.value, FeedHealth.starting);
  });

  test('a hub reset while not streaming does not un-null the health', () {
    hub.clear();
    expect(tracker.health.value, isNull);
  });
}
