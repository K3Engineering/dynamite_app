import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/monitor_pause.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Pause must pin the floated live edge to the confirmed end before the
/// 100 ms stall threshold of the ticker, otherwise the viewport would slide
/// into empty space for a hundred milliseconds after the click (the
/// graph_components `_kTickerStallMs`, `_kLiveEdgeCapMs` budget).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channels = kAdcChannelCount;

  testWidgets('pausing pins the live edge to the confirmed end', (
    tester,
  ) async {
    double nowMs = 0;
    final hub = DataHub(
      now: () => Duration(microseconds: (nowMs * 1000).round()),
    );
    final pause = MonitorPause(hub);
    final frame = Int32List(channels)..fillRange(0, channels, 100);

    void linkEvent() {
      nowMs += 18.75;
      for (var i = 0; i < 20; i++) {
        hub.addSampleFrame(frame);
      }
      hub.commitBatch(hub.totalSamples - 20);
    }

    final ctrl = GraphController(minLiveSpan: 200);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: GraphWorkspace(
              data: hub,
              ctrl: ctrl,
              unit: .raw,
              activeChannels: const [0],
            ),
          ),
        ),
      ),
    );

    // Flow ~1.2 s so the clock fit is mature, then step the injected clock
    // half a packet ahead so the envelope has room to live above the
    // confirmed end.
    for (var e = 0; e < 60; e++) {
      linkEvent();
      if (e % 3 == 0) await tester.pump(const Duration(milliseconds: 6));
    }
    nowMs += 10;
    expect(hub.projectedEndAt(), greaterThan(hub.totalSamples));

    // Hit pause: the pinning commit cannot rely on the ticker stopping
    // (lastDataAt is still fresh inside the 100 ms budget), so the hub must
    // force projectedEndAt to null / totalSamples immediately.
    pause.pause();
    expect(hub.projectedEndAt(), isNull);

    // Any geometry computed after the click must be frozen at totalSamples:
    // simulate a user zoom/pan/triggered _syncTicker at any point during
    // the pause.
    final int frozenTotal = hub.totalSamples;
    ctrl.zoom(1.2, 1.0, hub.totalSamples, hub.oldestSample);
    ctrl.applyWindow(
      frozenTotal - 400,
      400,
      hub.totalSamples,
      hub.oldestSample,
    );
    await tester.pump(const Duration(milliseconds: 500));

    pause.resume();
    // Resume drops the paused flag, but the protection is the same null
    // state until the next committed packet re-observes the device clock.
    expect(hub.projectedEndAt(), isNull);

    // The device ran during the pause (discarded), so the next batch lands
    // after a > 250 ms gap and re-anchors from a clean ring: the hub then
    // reports a projection again, and the tracker can glide.
    nowMs += 400;
    linkEvent();
    expect(hub.projectedEndAt(), isNotNull);

    // The graph itself survived all of it, with no pending paints.
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
