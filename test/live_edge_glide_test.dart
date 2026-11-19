import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/analysis_pane.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Paint smoke test for the device-clock-floated live views (graph_components
/// `_GraphGeometry` / `_computeGeometry`): rolling (locked-span), "everything"
/// (squeeze) and parked viewports, fed at the real link's cadence -- the
/// device makes one 20-sample batch per 20 ms of device time, surfaced at the
/// 18.75 ms connection interval, so an event usually delivers one batch,
/// every ~16th event none, and a jittered backlog flushes two. Frame pumps
/// BETWEEN deliveries exercise the gliding (ticker-driven) repaints with no
/// new data; no pixel assertions -- the point is the float-window math and
/// per-frame paint paths executing end to end without throwing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channels = kAdcChannelCount;

  testWidgets('floating live windows paint across the delivery cadence', (
    tester,
  ) async {
    // Injected PC clock for the DataHub's device-clock fit, advanced
    // manually: widget-test pump time is fake, the fit needs _its_ seconds.
    double nowMs = 0;
    final hub = DataHub(
      now: () => Duration(microseconds: (nowMs * 1000).round()),
    );
    final frame = Int32List(channels)..fillRange(0, channels, 100);

    // One connection event: deliver every batch whose 20 ms device deadline
    // passed (backlog adds one, mimicking a jittered two-packet event).
    int delivered = 0;
    void linkEvent({bool backlog = false}) {
      nowMs += 18.75;
      int ready = nowMs ~/ 20;
      if (backlog) ready += 1;
      while (delivered < ready) {
        final start = hub.totalSamples;
        for (var i = 0; i < 20; i++) {
          hub.addSampleFrame(frame);
        }
        hub.commitBatch(start);
        delivered++;
      }
    }

    final ctrl = GraphController(minLiveSpan: 200);
    Future<void> pumpFrames(int n) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 6));
      }
    }

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
              analysis: const AnalysisPaneSelection(
                kind: AnalysisPaneKind.derivative,
              ),
            ),
          ),
        ),
      ),
    );

    // Young stream (below the minLiveSpan floor), rolling locked window:
    // the minimap's floored 200-sample window and the graphs glide on the
    // pre-fit fallback projection.
    for (var e = 0; e < 8; e++) {
      linkEvent();
      await pumpFrames(3);
    }
    expect(tester.takeException(), isNull);

    // Fit maturity (past the 1 s minimum span), then squeeze "everything".
    for (var e = 0; e < 60; e++) {
      linkEvent(backlog: e % 25 == 0);
      if (e % 3 == 0) await pumpFrames(2);
    }
    expect(tester.takeException(), isNull);
    // The clock fit's edge runs at or ahead of the confirmed end.
    expect(hub.projectedEndAt(), greaterThanOrEqualTo(hub.totalSamples));

    ctrl.goLive(
      span: hub.totalSamples,
      totalSamples: hub.totalSamples,
      oldestSample: hub.oldestSample,
      generation: hub.dataGeneration,
    );
    expect(
      ctrl.viewport,
      isA<GraphLive>().having((v) => v.span, 'span', isNull),
    );
    for (var e = 0; e < 10; e++) {
      linkEvent();
      await pumpFrames(2);
    }
    expect(tester.takeException(), isNull);

    // Parked on a fixed window while the stream keeps flowing: the minimap
    // steps per packet, the box stays put.
    ctrl.applyWindow(
      500,
      400,
      hub.totalSamples,
      hub.oldestSample,
      generation: hub.dataGeneration,
    );
    expect(ctrl.isLive, isFalse);
    for (var e = 0; e < 6; e++) {
      linkEvent();
      await pumpFrames(2);
    }
    expect(tester.takeException(), isNull);

    // Back to live-rolling, then unmount: the ticker must be disposed before
    // the binding's no-pending-timers check.
    ctrl.goLive(
      span: 400,
      totalSamples: hub.totalSamples,
      oldestSample: hub.oldestSample,
      generation: hub.dataGeneration,
    );
    linkEvent();
    await pumpFrames(3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
