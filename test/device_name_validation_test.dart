import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/device_name.dart';

void main() {
  group('device-name grammar', () {
    test('accepts natural names up to the cap', () {
      expect(isValidDeviceName('Rack 4 (West)'), isTrue);
      expect(isValidDeviceName("Vlad's Rack"), isTrue);
      expect(isValidDeviceName('Bench-2_v3.1'), isTrue);
      expect(isValidDeviceName('A'), isTrue);
      expect(isValidDeviceName('A' * deviceNameMaxLength), isTrue);
    });

    test('rejects names outside the grammar', () {
      expect(isValidDeviceName(''), isFalse);
      expect(isValidDeviceName('A' * (deviceNameMaxLength + 1)), isFalse);
      // Must start with a letter or digit.
      expect(isValidDeviceName(' Rack'), isFalse);
      expect(isValidDeviceName('-Rack'), isFalse);
      expect(isValidDeviceName('.Rack'), isFalse);
      // Characters outside the allowed set.
      expect(isValidDeviceName('Rack,4'), isFalse);
      expect(isValidDeviceName('Rack"4'), isFalse);
      expect(isValidDeviceName('Rack\\4'), isFalse);
      expect(isValidDeviceName('Rack/4'), isFalse);
      expect(isValidDeviceName('Rack=4'), isFalse);
      expect(isValidDeviceName('Rack 4!'), isFalse);
      // Non-ASCII and invisible/control characters.
      expect(isValidDeviceName('Räck'), isFalse);
      expect(isValidDeviceName('Rack 4\u200B'), isFalse);
      expect(isValidDeviceName('Rack\n4'), isFalse);
    });
  });
}
