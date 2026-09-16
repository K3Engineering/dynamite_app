import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/models/graph_data_source.dart';
import 'package:dynamite_app/services/data_hub.dart';

/// Tests for `SampleStorageQueries.windowedStdDev`: window clamping, gap
/// exclusion, and the empty-window null.
void main() {
  DataHub hubWith(List<int> values) {
    final hub = DataHub();
    final frame = Int32List(kAdcChannelCount);
    for (final v in values) {
      frame.fillRange(0, kAdcChannelCount, v);
      hub.addSampleFrame(frame);
    }
    return hub;
  }

  test('no samples yields null', () {
    expect(DataHub().windowedStdDev(0, 0, 100), isNull);
  });

  test('constant series has zero sigma', () {
    final hub = hubWith(List.filled(100, 5000));
    expect(hub.windowedStdDev(0, 0, 100), closeTo(0, 1e-9));
  });

  test('alternating series yields its amplitude as sigma', () {
    final hub = hubWith([for (int i = 0; i < 1000; i++) i.isEven ? 100 : -100]);
    expect(hub.windowedStdDev(0, 0, 1000), closeTo(100, 1e-9));
  });

  test('a start before the oldest retained sample clamps', () {
    final hub = hubWith(List.filled(10, 7000));
    expect(hub.windowedStdDev(0, -10000, 10), closeTo(0, 1e-9));
  });

  test('gap samples contribute neither value nor count', () {
    final hub = hubWith([0, 0]);
    hub.addDroppedFrames(2); // two held samples of the pre-gap 0
    final frame = Int32List(kAdcChannelCount)
      ..fillRange(0, kAdcChannelCount, 1000);
    hub.addSampleFrame(frame);
    hub.addSampleFrame(frame);
    // Real samples are {0, 0, 1000, 1000}; including the held zeros would
    // yield ~471, not 500.
    expect(hub.windowedStdDev(0, 0, hub.totalSamples), closeTo(500, 1e-6));
  });

  test('an all-gap window yields null', () {
    final hub = hubWith([0]);
    hub.addDroppedFrames(4);
    expect(hub.windowedStdDev(0, 1, hub.totalSamples), isNull);
  });
}
