import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/storage_capacity.dart';

/// Tests for [StorageCapacity]'s derived numbers (the conservative runway
/// and the clamped bar fraction) and [userAgentMayAutoDelete]'s Chromium
/// detection — the pure logic behind the Sessions tab's capacity strip.
void main() {
  group('recordingRunway', () {
    test('applies the 0.9 safety factor at the worst-case write rate', () {
      const gb = 1024 * 1024 * 1024;
      const c = StorageCapacity(
        usedBytes: 0,
        availableBytes: gb,
        isPersistent: true,
      );
      expect(
        c.recordingRunway.inSeconds,
        (gb * 0.9 / kRecordingBytesPerSecond).floor(),
      );
    });

    test('zero available is zero runway', () {
      const c = StorageCapacity(
        usedBytes: 1024,
        availableBytes: 0,
        isPersistent: true,
      );
      expect(c.recordingRunway, Duration.zero);
    });
  });

  group('usedFraction', () {
    test('zero total is empty, not a divide-by-zero', () {
      const c = StorageCapacity(
        usedBytes: 0,
        availableBytes: 0,
        isPersistent: false,
      );
      expect(c.usedFraction, 0);
    });

    test('clamps usage reported above quota (fuzzed web estimate)', () {
      const c = StorageCapacity(
        usedBytes: 200,
        availableBytes: 0,
        isPersistent: false,
      );
      expect(c.usedFraction, 1.0);
    });

    test('plain ratio otherwise', () {
      const c = StorageCapacity(
        usedBytes: 1,
        availableBytes: 3,
        isPersistent: true,
      );
      expect(c.usedFraction, 0.25);
    });
  });

  group('userAgentMayAutoDelete', () {
    test('Chrome and Chromium forks are safe', () {
      expect(
        userAgentMayAutoDelete(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        ),
        isFalse,
      );
      // Edge appends Edg/, Opera OPR/ — both keep the Chrome/ token.
      expect(
        userAgentMayAutoDelete(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0',
        ),
        isFalse,
      );
    });

    test('Safari and Firefox warn', () {
      expect(
        userAgentMayAutoDelete(
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
          'Safari/605.1.15',
        ),
        isTrue,
      );
      expect(
        userAgentMayAutoDelete(
          'Mozilla/5.0 (X11; Linux x86_64; rv:127.0) Gecko/20100101 '
          'Firefox/127.0',
        ),
        isTrue,
      );
    });
  });
}
