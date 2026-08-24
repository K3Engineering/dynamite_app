import 'package:dynamite_app/models/channel_limits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChannelLimits.isClipped', () {
    test('rails and interior', () {
      expect(ChannelLimits.isClipped(ChannelLimits.clipRawPos), isTrue);
      expect(ChannelLimits.isClipped(ChannelLimits.clipRawNeg), isTrue);
      expect(ChannelLimits.isClipped(0), isFalse);
      expect(ChannelLimits.isClipped(ChannelLimits.clipRawPos - 1), isFalse);
      expect(ChannelLimits.isClipped(ChannelLimits.clipRawNeg + 1), isFalse);
    });
  });
}
