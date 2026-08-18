import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dynamite_app/services/app_settings.dart';
import 'package:dynamite_app/screens/live_tab.dart';
import 'package:dynamite_app/models/device_profile.dart';
import 'package:dynamite_app/services/data_hub.dart';
import 'package:dynamite_app/models/feed_health.dart';
import 'package:dynamite_app/services/rig_flash_transport.dart';
import 'package:dynamite_app/services/rig_state.dart';
import 'package:dynamite_app/widgets/graph_components.dart';

/// Widget test for the live stats' Peak row: it reports the max over the
/// graph's viewport, so moving the viewport must update the row even when no
/// new packets arrive (only the GraphController notifies).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Peak row follows the graph window', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final hub = DataHub();
    // 1000 samples: 900 over the first half, 700 over the second. The live
    // reading (last sample) is 700; the full-view peak is 900.
    final frame = Int32List(kAdcChannelCount);
    for (int i = 0; i < 1000; i++) {
      frame.fillRange(0, kAdcChannelCount, i < 500 ? 900 : 700);
      hub.addSampleFrame(frame);
    }
    // Live, no locked span: the viewport shows everything.
    final ctrl = GraphController();
    // No board calibration: the effective unit is raw counts.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveStats(
            settings: AppSettings(prefs: prefs),
            rig: RigState(transport: _FakeTransport(), prefs: prefs),
            hub: hub,
            ctrl: ctrl,
            healthListenable: ValueNotifier<FeedHealth?>(null),
          ),
        ),
      ),
    );

    // All four channels fed identically: one value per cell.
    expect(find.text('+900'), findsNWidgets(kAdcChannelCount)); // Peak row
    expect(find.text('+700'), findsNWidgets(kAdcChannelCount)); // Live row

    // Second half in view: the 900s are scrolled out of the window.
    ctrl.applyWindow(500, 500, hub.totalSamples, hub.oldestSample);
    await tester.pump();
    expect(find.text('+900'), findsNothing);
    expect(find.text('+700'), findsNWidgets(kAdcChannelCount * 2));

    // First half in view (parked, not at the live edge): the peak returns.
    ctrl.applyWindow(0, 500, hub.totalSamples, hub.oldestSample);
    await tester.pump();
    expect(ctrl.isLive, isFalse);
    expect(find.text('+900'), findsNWidgets(kAdcChannelCount));
    expect(find.text('+700'), findsNWidgets(kAdcChannelCount));
  });
}

/// LiveStats reads only the rig's channel titles; the flash transport is
/// never exercised.
class _FakeTransport implements RigFlashTransport {
  @override
  String get connectedDeviceId => 'dev1';
  @override
  String get connectedDeviceName => 'Bench unit';
  @override
  Future<void> writeFlashDoc(String doc) async {}
  @override
  Future<String?> readFlashDoc() async => null;
}
