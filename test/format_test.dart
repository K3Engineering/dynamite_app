import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/utils/format.dart';

/// Tests for the shared formatters: [formatDuration]'s unit ladder,
/// [formatDate]/[formatTimestamp]'s ISO zero-padding, and
/// [formatRelativeAge]'s coarse bucket ladder — the Devices tab's
/// "Last seen/connected" ages deliberately change rarely instead of ticking
/// every second.
void main() {
  group('formatDuration', () {
    test('below a minute is seconds only', () {
      expect(formatDuration(Duration.zero), '0s');
      expect(formatDuration(const Duration(seconds: 59)), '59s');
    });

    test('below an hour is minutes and seconds', () {
      expect(formatDuration(const Duration(seconds: 60)), '1m 0s');
      expect(formatDuration(const Duration(minutes: 3, seconds: 12)), '3m 12s');
      expect(formatDuration(const Duration(minutes: 59, seconds: 59)), '59m 59s');
    });

    test('an hour and beyond drops the seconds', () {
      expect(formatDuration(const Duration(hours: 1)), '1h 0m');
      expect(formatDuration(const Duration(hours: 1, minutes: 15)), '1h 15m');
      expect(formatDuration(const Duration(hours: 26, minutes: 30)), '26h 30m');
    });
  });

  group('formatDate', () {
    test('ISO Y-M-D, zero-padded', () {
      expect(formatDate(DateTime(2026, 7, 20)), '2026-07-20');
      expect(formatDate(DateTime(2026, 1, 5)), '2026-01-05');
      expect(formatDate(DateTime(2025, 12, 31)), '2025-12-31');
    });
  });

  group('formatTimestamp', () {
    test('ISO date plus 24h zero-padded time, minutes precision', () {
      expect(formatTimestamp(DateTime(2026, 7, 29, 14, 5)), '2026-07-29 14:05');
      expect(formatTimestamp(DateTime(2026, 7, 29, 9, 5)), '2026-07-29 09:05');
      expect(formatTimestamp(DateTime(2026, 7, 29, 23, 59)), '2026-07-29 23:59');
      // Seconds never render.
      expect(
        formatTimestamp(DateTime(2026, 7, 29, 14, 5, 59)),
        '2026-07-29 14:05',
      );
    });
  });

  test('under five seconds is "just now"', () {
    expect(formatRelativeAge(Duration.zero), 'just now');
    expect(formatRelativeAge(const Duration(seconds: 4)), 'just now');
  });

  test('second buckets widen 5 / 15 / 30', () {
    expect(formatRelativeAge(const Duration(seconds: 5)), '>5 seconds ago');
    expect(formatRelativeAge(const Duration(seconds: 14)), '>5 seconds ago');
    expect(formatRelativeAge(const Duration(seconds: 15)), '>15 seconds ago');
    expect(formatRelativeAge(const Duration(seconds: 29)), '>15 seconds ago');
    expect(formatRelativeAge(const Duration(seconds: 30)), '>30 seconds ago');
    expect(formatRelativeAge(const Duration(seconds: 59)), '>30 seconds ago');
  });

  test('minute buckets widen 1 / 5 / 15 / 30', () {
    expect(formatRelativeAge(const Duration(seconds: 60)), '>1 minute ago');
    expect(
      formatRelativeAge(const Duration(minutes: 4, seconds: 59)),
      '>1 minute ago',
    );
    expect(formatRelativeAge(const Duration(minutes: 5)), '>5 minutes ago');
    expect(formatRelativeAge(const Duration(minutes: 14)), '>5 minutes ago');
    expect(formatRelativeAge(const Duration(minutes: 15)), '>15 minutes ago');
    expect(formatRelativeAge(const Duration(minutes: 29)), '>15 minutes ago');
    expect(formatRelativeAge(const Duration(minutes: 30)), '>30 minutes ago');
    expect(formatRelativeAge(const Duration(minutes: 59)), '>30 minutes ago');
  });

  test('an hour and beyond caps at ">1 hour ago"', () {
    expect(formatRelativeAge(const Duration(hours: 1)), '>1 hour ago');
    expect(formatRelativeAge(const Duration(hours: 30)), '>1 hour ago');
  });
}
