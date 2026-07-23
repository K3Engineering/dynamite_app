import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/utils/format.dart';

/// Tests for [formatRelativeAge]'s coarse bucket ladder — the Devices tab's
/// "Last seen/connected" ages deliberately change rarely instead of ticking
/// every second.
void main() {
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
