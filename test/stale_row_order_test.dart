import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/screens/devices_tab.dart'
    show compareStaleRowsByRecency;

/// Tests for [compareStaleRowsByRecency], the ordering within the Devices
/// tab's stale (greyed) row group: most recently seen first, so the rows'
/// "Last seen" ages increase monotonically down the list and a just-staled
/// device (likely still of interest) leads the group. The comparator takes
/// the rows' lastAliveMs stamps directly (ms since epoch, nullable) so it
/// stays pure and testable without constructing BleDevices.
void main() {
  // Fixed reference clock; stamps are computed backwards from it.
  final now = DateTime(2026, 7, 29, 12).millisecondsSinceEpoch;

  group('recency ordering', () {
    test('the more recent stamp sorts first', () {
      expect(compareStaleRowsByRecency(now - 2000, now - 9000), isNegative);
      expect(compareStaleRowsByRecency(now - 9000, now - 2000), isPositive);
    });

    test('equal stamps compare as equal', () {
      expect(compareStaleRowsByRecency(now - 5000, now - 5000), 0);
    });

    test('sorting a shuffled group yields most-recent-first', () {
      final stamps = [now - 90000, now - 12000, now - 45000, now - 11000];
      stamps.sort(compareStaleRowsByRecency);
      expect(stamps, [now - 11000, now - 12000, now - 45000, now - 90000]);
    });
  });

  group('null stamps (defensive)', () {
    // A stale row always carries a stamp (bleRowSubtitle only flags stale
    // when one exists), but the comparator must still be total: a null
    // stamp sorts as oldest and sinks to the end of the group.
    test('a null stamp sorts after any real stamp', () {
      expect(compareStaleRowsByRecency(null, now - 90000), isPositive);
      expect(compareStaleRowsByRecency(now - 90000, null), isNegative);
    });

    test('two null stamps compare as equal', () {
      expect(compareStaleRowsByRecency(null, null), 0);
    });

    test('nulls sink to the end of a sorted group', () {
      final stamps = <int?>[null, now - 45000, null, now - 12000];
      stamps.sort(compareStaleRowsByRecency);
      expect(stamps, [now - 12000, now - 45000, null, null]);
    });
  });
}
