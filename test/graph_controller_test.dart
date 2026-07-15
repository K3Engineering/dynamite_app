import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/graph_components.dart';

/// Unit tests for the [GraphController] viewport state machine. It is pure
/// Dart (no painting, no widgets): every mutation method takes the current data
/// shape as plain ints, so we can drive it directly without a GraphDataSource.
void main() {
  group('GraphController initial state', () {
    test('starts live with a null window and no locked span', () {
      final ctrl = GraphController();
      expect(ctrl.isLive, isTrue);
      expect(ctrl.viewEnd, isNull);
      expect(ctrl.liveSpan, isNull);
      expect(ctrl.viewStart, 0);
    });

    test('effectiveRange in live mode with no locked span shows all data', () {
      final ctrl = GraphController();
      expect(ctrl.effectiveRange(1000, 0), (0, 1000));
    });

    test('a positive minLiveSpan locks the initial scrolling window', () {
      final ctrl = GraphController(minLiveSpan: 2000);
      expect(ctrl.liveSpan, 2000);
      // Less data than the min span: window extends to a negative start.
      expect(ctrl.effectiveRange(1000, 0), (-1000, 1000));
    });

    test('bufferCapacity clamps the live span', () {
      final ctrl = GraphController(minLiveSpan: 2000);
      expect(ctrl.effectiveRange(1000, 0, bufferCapacity: 500), (500, 1000));
    });
  });

  group('GraphController.setWindow', () {
    test('exits live mode and reports the exact window', () {
      final ctrl = GraphController();
      ctrl.setWindow(100, 300);
      expect(ctrl.isLive, isFalse);
      expect(ctrl.viewStart, 100);
      expect(ctrl.viewEnd, 300);
      expect(ctrl.liveSpan, isNull);
      expect(ctrl.effectiveRange(1000, 0), (100, 300));
    });

    test('clamps a reversed end to start + 1', () {
      final ctrl = GraphController();
      ctrl.setWindow(100, 50);
      expect(ctrl.effectiveRange(1000, 0), (100, 101));
    });
  });

  group('GraphController.applyWindow', () {
    test('clamps the left edge to the oldest available sample', () {
      final ctrl = GraphController();
      ctrl.applyWindow(-50, 200, 1000, 0);
      expect(ctrl.viewStart, 0);
      expect(ctrl.viewEnd, 200);
      expect(ctrl.isLive, isFalse);
    });

    test('snaps to live mode and locks the current span at the right edge', () {
      final ctrl = GraphController();
      ctrl.applyWindow(800, 200, 1000, 0);
      expect(ctrl.isLive, isTrue);
      expect(ctrl.liveSpan, 200);
      expect(ctrl.viewEnd, isNull);
      expect(ctrl.effectiveRange(1000, 0), (800, 1000));
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
      final (s, e) = (ctrl.viewStart, ctrl.viewEnd!);
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
      expect(ctrl.liveSpan, 500);
      expect(ctrl.effectiveRange(1000, 0), (500, 1000));
    });

    test('zooming out to the max span clears liveSpan (auto-expand)', () {
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
      expect(ctrl.liveSpan, isNull);
      expect(ctrl.effectiveRange(500, 0), (0, 500));
    });
  });

  group('GraphController.pan / centerOn', () {
    test('pan shifts the window by the delta', () {
      final ctrl = GraphController();
      ctrl.setWindow(100, 300);
      ctrl.pan(50, 1000, 0, 600000);
      expect(ctrl.viewStart, 150);
      expect(ctrl.viewEnd, 350);
      expect(ctrl.isLive, isFalse);
    });

    test('centerOn centers the current span on a sample', () {
      final ctrl = GraphController();
      ctrl.setWindow(100, 300); // span 200
      ctrl.centerOn(500, 1000, 0, 600000);
      expect(ctrl.viewStart, 400);
      expect(ctrl.viewEnd, 600);
    });
  });

  group('GraphController.isSqueeze / reset', () {
    test('isSqueeze is true when the window spans all available data', () {
      final ctrl = GraphController();
      expect(ctrl.isSqueeze(1000, 0), isTrue);
      ctrl.goLive(span: 200, totalSamples: 1000, oldestSample: 0);
      expect(ctrl.isSqueeze(1000, 0), isFalse);
    });

    test('reset returns to live full-view', () {
      final ctrl = GraphController();
      ctrl.setWindow(100, 300);
      ctrl.reset();
      expect(ctrl.isLive, isTrue);
      expect(ctrl.viewEnd, isNull);
      expect(ctrl.viewStart, 0);
      expect(ctrl.liveSpan, isNull);
    });
  });

  group('GraphController notifies listeners', () {
    test('every mutating call fires exactly once', () {
      final ctrl = GraphController();
      var count = 0;
      ctrl.addListener(() => count++);

      ctrl.setWindow(100, 300);
      expect(count, 1);
      ctrl.reset();
      expect(count, 2);
      ctrl.goLive(totalSamples: 1000, oldestSample: 0);
      expect(count, 3);
    });
  });
}
