import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart' show AvailabilityState;

import 'package:dynamite_app/widgets/bt_icon.dart';

/// Tests for [topIndicatorMode], the "quiet when nominal" presentation
/// policy behind [BluetoothIndicator]: an icon only when the glyph carries
/// real information (scan progress, adapter failure), text-only for
/// powered-on nominal states, and fully silent whenever the Devices tab's
/// empty block is on screen as the single voice.
void main() {
  TopIndicatorMode mode({
    AvailabilityState availability = AvailabilityState.poweredOn,
    bool isScanning = false,
    bool emptyBlockVisible = false,
  }) => topIndicatorMode(
    availability: availability,
    isScanning: isScanning,
    emptyBlockVisible: emptyBlockVisible,
  );

  test('the empty block showing forces quiet in every adapter state', () {
    for (final a in AvailabilityState.values) {
      expect(
        mode(availability: a, emptyBlockVisible: true),
        TopIndicatorMode.quiet,
        reason: 'availability $a',
      );
    }
  });

  test('scanning shows the spinner and label', () {
    expect(mode(isScanning: true), TopIndicatorMode.iconAndLabel);
  });

  test('adapter failures keep their distinct icon and label', () {
    // Distinct glyphs (off / permission / unsupported / startup) carry real
    // information; they reach the indicator only when the empty block isn't
    // covering them (a stale populated list — see the quiet case above).
    for (final a in AvailabilityState.values) {
      if (a == AvailabilityState.poweredOn) continue;
      expect(
        mode(availability: a),
        TopIndicatorMode.iconAndLabel,
        reason: 'availability $a',
      );
    }
  });

  test('powered-on nominal is text-only', () {
    // "Tap a device to connect" renders without an icon; an empty label
    // (a link is busy) renders nothing at all.
    expect(mode(), TopIndicatorMode.textOnly);
  });
}
