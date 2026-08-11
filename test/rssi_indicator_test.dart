import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/rssi_indicator.dart' show rssiLevel;

/// Tests for [rssiLevel]'s 0–3 ladder. The thresholds suit a nearby BLE
/// sensor: strong ≥ −55, good ≥ −65, fair ≥ −75, weak below.
void main() {
  test('boundary values sit on their documented rungs', () {
    expect(rssiLevel(-30), 3);
    expect(rssiLevel(-55), 3);
    expect(rssiLevel(-56), 2);
    expect(rssiLevel(-65), 2);
    expect(rssiLevel(-66), 1);
    expect(rssiLevel(-75), 1);
    expect(rssiLevel(-76), 0);
    expect(rssiLevel(-100), 0);
  });
}
