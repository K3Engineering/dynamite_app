import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/models/display_unit.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Paint smoke test for a parked window that retention eviction overtook
/// (see [GraphController.effectiveRange]): partially drained windows draw
/// clipped at the retention head, fully drained ones draw the "beyond
/// history" label. No pixel assertions -- the point is the paint paths (both
/// panes, the minimap's clamped viewport box, the segment cache covering
/// ranges past the ring's head) executing end to end without throwing. This
/// is the only way to reach these states without waiting out the ring
/// (~10 min of streaming).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channels = kAdcChannelCount;

  testWidgets('parked windows paint through retention eviction', (
    tester,
  ) async {
    final hub = DataHub();
    final frame = Int32List(channels)..fillRange(0, channels, 100);
    // Past the ring capacity the head of retention advances one per sample.
    void feed(int count) {
      for (var i = 0; i < count; i++) {
        hub.addSampleFrame(frame);
      }
    }

    final ctrl = GraphController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: GraphWorkspace(
              data: hub,
              ctrl: ctrl,
              unit: DisplayUnit.raw,
              activeChannels: const [0],
              showDerivative: true,
            ),
          ),
        ),
      ),
    );

    // Park on [0, 5000), then let the ring wrap eat the window from the
    // left (oldestSample lags total by maxDataSz once past capacity).
    feed(10000);
    ctrl.applyWindow(0, 5000, hub.totalSamples, hub.oldestSample);

    // Half drained: samples [0, 2500) of the window are evicted.
    feed(DataHub.maxDataSz + 2500 - hub.totalSamples);
    expect(hub.oldestSample, 2500);
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(ctrl.isLive, isFalse);

    // Fully drained: the whole window sits left of the retention head, the
    // panes draw the "beyond history" label and the minimap box is
    // off-canvas left.
    feed(2500);
    expect(hub.oldestSample, 5000);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);

    // A pan re-anchors the window onto the retention head (see
    // graph_controller_test), back over drawable data.
    ctrl.pan(0, hub.totalSamples, hub.oldestSample);
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Unmount before the test ends: the live-follow ticker must be disposed
    // before the binding's no-pending-timers check.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
