import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Unit tests for the [GraphController] viewport state machine. It is pure
/// Dart (no painting, no widgets): every mutation method takes the current data
/// shape as plain ints, so we can drive it directly without a GraphDataSource.
///
/// The viewport itself is a sealed union ([GraphLive] / [GraphWindow]); the
/// tests observe it exclusively through [GraphController.isLive] and
/// [GraphController.effectiveRange], the same API the app consumes.
void main() {
  group('GraphController initial state', () {
    test('starts live', () {
      final ctrl = GraphController();
      expect(ctrl.isLive, isTrue);
    });

    test('effectiveRange in live mode with no locked span shows all data', () {
      final ctrl = GraphController();
      expect(ctrl.effectiveRange(1000, 0), (0, 1000));
    });

    test('a positive minLiveSpan locks the initial scrolling window', () {
      final ctrl = GraphController(minLiveSpan: 2000);
      // Enough data: the locked span shows from the right edge.
      expect(ctrl.effectiveRange(5000, 0), (3000, 5000));
      // Less data than the min span: window extends to a negative start.
      expect(ctrl.effectiveRange(1000, 0), (-1000, 1000));
    });

    test('bufferCapacity clamps the live span', () {
      final ctrl = GraphController(minLiveSpan: 2000);
      expect(ctrl.effectiveRange(1000, 0, bufferCapacity: 500), (500, 1000));
    });
  });

  group('GraphController.applyWindow', () {
    test('clamps the left edge to the oldest available sample', () {
      final ctrl = GraphController();
      ctrl.applyWindow(-50, 200, 1000, 0);
      expect(ctrl.isLive, isFalse);
      expect(ctrl.effectiveRange(1000, 0), (0, 200));
    });

    test('snaps to live mode and locks the current span at the right edge', () {
      final ctrl = GraphController();
      ctrl.applyWindow(800, 200, 1000, 0);
      expect(ctrl.isLive, isTrue);
      // Locked to the 200-sample span: the window tracks the right edge.
      expect(ctrl.effectiveRange(1000, 0), (800, 1000));
      expect(ctrl.effectiveRange(1200, 0), (1000, 1200));
    });
  });

  group('GraphController.zoomTo', () {
    test('clamps the span to a ~50 sample minimum', () {
      final ctrl = GraphController();
      ctrl.zoomTo(
        10,
        0.5,
        baseStart: 0,
        baseSpan: 1000,
        anchorLiveEdge: false,
        totalSamples: 1000,
        oldestSample: 0,
      );
      final (s, e) = ctrl.effectiveRange(1000, 0);
      expect(e - s, 50);
      expect(ctrl.isLive, isFalse);
    });

    test('anchors to the live right edge when focalFraction > 0.8', () {
      final ctrl = GraphController();
      ctrl.zoomTo(
        500,
        0.9,
        baseStart: 0,
        baseSpan: 1000,
        anchorLiveEdge: true,
        totalSamples: 1000,
        oldestSample: 0,
      );
      expect(ctrl.isLive, isTrue);
      expect(ctrl.effectiveRange(1000, 0), (500, 1000));
    });

    test('zooming out to the max span auto-expands with the data', () {
      final ctrl = GraphController();
      ctrl.zoomTo(
        10000,
        0.5,
        baseStart: 0,
        baseSpan: 500,
        anchorLiveEdge: false,
        totalSamples: 500,
        oldestSample: 0,
      );
      expect(ctrl.isLive, isTrue);
      // No locked span: the window grows as new data arrives.
      expect(ctrl.effectiveRange(500, 0), (0, 500));
      expect(ctrl.effectiveRange(700, 0), (0, 700));
    });
  });

  group('GraphController.pan / centerOn', () {
    test('pan shifts the window by the delta', () {
      final ctrl = GraphController();
      ctrl.applyWindow(100, 200, 1000, 0);
      ctrl.pan(50, 1000, 0, 600000);
      expect(ctrl.isLive, isFalse);
      expect(ctrl.effectiveRange(1000, 0), (150, 350));
    });

    test('centerOn centers the current span on a sample', () {
      final ctrl = GraphController();
      ctrl.applyWindow(100, 200, 1000, 0); // span 200
      ctrl.centerOn(500, 1000, 0, 600000);
      expect(ctrl.effectiveRange(1000, 0), (400, 600));
    });
  });

  group('GraphController notifies listeners', () {
    test('every mutating call fires exactly once', () {
      final ctrl = GraphController();
      var count = 0;
      ctrl.addListener(() => count++);

      ctrl.applyWindow(100, 200, 1000, 0);
      expect(count, 1);
      ctrl.goLive(totalSamples: 1000, oldestSample: 0);
      expect(count, 2);
      ctrl.applyWindow(300, 200, 1000, 0);
      expect(count, 3);
    });
  });

  /// The viewport-side half of the per-stream reset: when a new device stream
  /// clears the hub, the live tab snaps the controller back to live follow
  /// via [GraphController.goLive]. [effectiveRange] is additionally
  /// self-defensive against stale parked windows (it clamps rather than
  /// throwing), so the goLive call is a UX nicety, not a crash guard.
  group('GraphController across a stream reset', () {
    test('a stale panned window clamps instead of throwing', () {
      // A window parked deep in history (set while the old stream had plenty
      // of data) evaluated against a cleared hub: the start clamp runs first,
      // so the end clamp can never receive inverted limits.
      final ctrl = GraphController(minLiveSpan: 20000);
      ctrl.applyWindow(100000, 100000, 300000, 0); // user panned into history
      expect(ctrl.effectiveRange(0, 0), (0, 1));
      expect(ctrl.effectiveRange(50, 0), (49, 50));
    });

    test('goLive restores a safe live-follow range', () {
      final ctrl = GraphController(minLiveSpan: 20000);
      ctrl.applyWindow(100000, 100000, 300000, 0);

      ctrl.goLive(totalSamples: 0, oldestSample: 0);

      final (start, end) = ctrl.effectiveRange(
        0,
        0,
        bufferCapacity: DataHub.maxDataSz,
      );
      expect(ctrl.isLive, isTrue);
      expect(end, 0);
      expect(start, -20000);
    });
  });
}
