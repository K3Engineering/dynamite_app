import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/widgets/rssi_indicator.dart';

void main() {
  group('rssiLevel', () {
    test('maps dBm to 0–3 bars at the -55/-65/-75 thresholds', () {
      expect(rssiLevel(-40), 3);
      expect(rssiLevel(-55), 3);
      expect(rssiLevel(-56), 2);
      expect(rssiLevel(-65), 2);
      expect(rssiLevel(-66), 1);
      expect(rssiLevel(-75), 1);
      expect(rssiLevel(-76), 0);
      expect(rssiLevel(-100), 0);
    });
  });
}
