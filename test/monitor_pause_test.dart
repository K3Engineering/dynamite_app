import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/services/monitor_pause.dart';

Int32List frameOf(int v) =>
    Int32List.fromList([for (int i = 0; i < kAdcChannelCount; i++) v]);

/// [MonitorPause] itself is only the flag plus the freeze-point marker; the
/// decoder gate honoring the flag lives in adc_packet_decoder_test.dart.
void main() {
  late DataHub hub;
  late MonitorPause pause;

  setUp(() {
    hub = DataHub();
    pause = MonitorPause(hub);
  });

  test('pause/resume flip the flag and notify', () {
    var notifies = 0;
    pause.addListener(() => notifies++);

    pause.pause();
    expect(pause.paused, isTrue);
    pause.resume();
    expect(pause.paused, isFalse);
    expect(notifies, 2);
  });

  test('pause marks the freeze point with a one-sample held gap', () {
    hub.addSampleFrame(frameOf(123));
    hub.commitBatch(0);
    final frozen = hub.totalSamples;

    pause.pause();

    expect(hub.totalSamples, frozen + 1);
    expect(hub.gaps.contains(frozen), isTrue);
    // The marker holds the last real value, and the held live edge is what
    // grays the stats table's live row for the pause's duration.
    expect(hub.rawAt(0, frozen), 123);
    expect(hub.liveEdgeIsGap, isTrue);
  });

  test('pause with no data injects no marker', () {
    pause.pause();
    expect(hub.totalSamples, 0);
    expect(pause.paused, isTrue);
  });

  test('repeat calls of the same transition are inert', () {
    hub.addSampleFrame(frameOf(1));
    var notifies = 0;
    pause.addListener(() => notifies++);

    pause.pause();
    pause.pause();
    expect(hub.totalSamples, 2); // one marker only
    pause.resume();
    pause.resume();
    expect(notifies, 2);
  });

  test('a hub clear (new stream) ends the pause: nothing left to freeze', () {
    hub.addSampleFrame(frameOf(1));
    pause.pause();

    hub.clear();

    expect(pause.paused, isFalse);
  });
}
