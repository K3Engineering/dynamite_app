import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/screens/devices_tab.dart'
    show
        InactiveRowMood,
        InactiveRowVisual,
        inactiveRowVisual,
        staleCardTintAlpha;
import 'package:dynamite_app/services/ble_link_manager.dart'
    show BleLinkManager;

/// Tests for [inactiveRowVisual], the inactive device row's full presentation
/// mapping (icon/colors/subtitle + the mood that drives stale-last ordering).
/// The mood priority is the point: a recorded connect failure outranks
/// staleness (actionable beats maybe-gone), which outranks the normal look.
void main() {
  final colors = ColorScheme.fromSeed(seedColor: Colors.blue);
  // Fixed reference clock; ages are computed backwards from it.
  final now = DateTime(2026, 7, 22, 12).millisecondsSinceEpoch;
  final staleMs = BleLinkManager.deviceStaleAfter.inMilliseconds;

  InactiveRowVisual row({
    int? scanRssi,
    int? lastAliveMs,
    bool supportsScanRssi = true,
    String? failureHint,
  }) => inactiveRowVisual(
    scanRssi: scanRssi,
    lastAliveMs: lastAliveMs,
    nowMs: now,
    supportsScanRssi: supportsScanRssi,
    failureHint: failureHint,
    colors: colors,
  );

  group('mood priority', () {
    test('a failure hint outranks an otherwise-stale row', () {
      final v = row(lastAliveMs: now - 60000, failureHint: "Couldn't connect");
      expect(v.mood, InactiveRowMood.failed);
      expect(v.icon, Icons.error_outline);
      expect(v.iconColor, colors.error);
      expect(v.subtitle, "Couldn't connect");
      expect(v.subtitleColor, colors.error);
      // No dimming: the failure treatment replaces the stale one.
      expect(v.cardColor, isNull);
      expect(v.titleColor, isNull);
    });

    test('a stale row without a failure is de-emphasized', () {
      final v = row(scanRssi: -58, lastAliveMs: now - staleMs - 1);
      expect(v.mood, InactiveRowMood.stale);
      expect(v.icon, Icons.bluetooth);
      // The card tint is an explicit onSurface-over-surface blend — and
      // crucially NOT the default card color (this app's M2-era schemes fall
      // the M3 container roles back to `surface`, an invisible no-op; the
      // blend is what makes the stale card visibly distinct).
      expect(
        v.cardColor,
        Color.alphaBlend(
          colors.onSurface.withValues(alpha: staleCardTintAlpha),
          colors.surface,
        ),
      );
      expect(v.cardColor, isNot(colors.surface));
      expect(v.titleColor, isNotNull);
      expect(v.subtitleColor, isNotNull);
      // The aged RSSI stays suppressed; the age text carries through.
      expect(v.subtitle, startsWith('Last seen'));
    });

    test('a fresh row gets the normal look', () {
      final v = row(scanRssi: -58, lastAliveMs: now - 3000);
      expect(v.mood, InactiveRowMood.normal);
      expect(v.iconColor, colors.outline);
      expect(v.subtitle, 'RSSI: -58 dBm');
      expect(v.cardColor, isNull);
      expect(v.titleColor, isNull);
      expect(v.subtitleColor, isNull);
    });

    test('exactly at the stale boundary is still normal', () {
      expect(row(lastAliveMs: now - staleMs).mood, InactiveRowMood.normal);
    });
  });

  group('no liveness data (legacy fallbacks)', () {
    test('a reading renders as dBm with the normal look', () {
      final v = row(scanRssi: -58);
      expect(v.mood, InactiveRowMood.normal);
      expect(v.subtitle, 'RSSI: -58 dBm');
    });

    test('no reading possible (web) leaves the subtitle slot empty', () {
      final v = row(supportsScanRssi: false);
      expect(v.mood, InactiveRowMood.normal);
      expect(v.subtitle, isNull);
    });

    test('web staleness comes from the last-connected stamp', () {
      final v = row(lastAliveMs: now - staleMs - 1, supportsScanRssi: false);
      expect(v.mood, InactiveRowMood.stale);
      expect(v.subtitle, startsWith('Last connected'));
    });
  });
}
