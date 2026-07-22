import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/screens/devices_tab.dart' show bleRowSubtitle;
import 'package:dynamite_app/services/ble_link_manager.dart'
    show BleLinkManager;

/// Tests for [bleRowSubtitle], the inactive BLE row's liveness subtitle.
/// The web cases are the point of the mapping: Web Bluetooth can never
/// deliver a scan RSSI (requestDevice() has none, watchAdvertisements is
/// abandoned), so the row shows a connection-based "Last connected" age
/// instead of a permanent "RSSI: --" placeholder — and any proof of life
/// older than [BleLinkManager.deviceStaleAfter] flips the row stale.
void main() {
  // Fixed reference clock; ages are computed backwards from it.
  final now = DateTime(2026, 7, 22, 12).millisecondsSinceEpoch;
  final staleMs = BleLinkManager.deviceStaleAfter.inMilliseconds;

  ({String text, bool stale})? row({
    int? scanRssi,
    int? lastAliveMs,
    required bool supportsScanRssi,
  }) => bleRowSubtitle(
    scanRssi: scanRssi,
    lastAliveMs: lastAliveMs,
    nowMs: now,
    supportsScanRssi: supportsScanRssi,
  );

  group('no liveness data (legacy fallbacks)', () {
    test('a reading renders as dBm on any platform', () {
      expect(
        row(scanRssi: -58, supportsScanRssi: true),
        (text: 'RSSI: -58 dBm', stale: false),
      );
      expect(
        row(scanRssi: -58, supportsScanRssi: false),
        (text: 'RSSI: -58 dBm', stale: false),
      );
    });

    test('no reading yet on an RSSI-capable platform is a transient '
        'placeholder', () {
      expect(row(supportsScanRssi: true), (text: 'RSSI: --', stale: false));
    });

    test('no reading possible (web) drops the RSSI slot entirely', () {
      expect(row(supportsScanRssi: false), isNull);
    });
  });

  group('fresh proof of life', () {
    test('native prefers the live RSSI while fresh', () {
      expect(
        row(scanRssi: -58, lastAliveMs: now - 3000, supportsScanRssi: true),
        (text: 'RSSI: -58 dBm', stale: false),
      );
    });

    test('native with no reading keeps the transient placeholder while fresh',
        () {
      expect(
        row(lastAliveMs: now - 3000, supportsScanRssi: true),
        (text: 'RSSI: --', stale: false),
      );
    });

    test('web shows "Last connected" while fresh', () {
      expect(
        row(lastAliveMs: now - 3000, supportsScanRssi: false),
        (text: 'Last connected just now', stale: false),
      );
    });

    test('exactly at the stale boundary is still fresh', () {
      expect(
        row(lastAliveMs: now - staleMs, supportsScanRssi: false)!.stale,
        isFalse,
      );
    });
  });

  group('stale proof of life', () {
    test('one millisecond past the boundary is stale', () {
      final r = row(
        lastAliveMs: now - staleMs - 1,
        supportsScanRssi: false,
      );
      expect(r, (text: 'Last connected >5 seconds ago', stale: true));
    });

    test('native switches to "Last seen" and suppresses the aged RSSI', () {
      expect(
        row(scanRssi: -58, lastAliveMs: now - 20000, supportsScanRssi: true),
        (text: 'Last seen >15 seconds ago', stale: true),
      );
    });

    test('long-stale ages render in the coarse ladder', () {
      expect(
        row(lastAliveMs: now - 90000, supportsScanRssi: true),
        (text: 'Last seen >1 minute ago', stale: true),
      );
      expect(
        row(lastAliveMs: now - 7200000, supportsScanRssi: false),
        (text: 'Last connected >1 hour ago', stale: true),
      );
    });
  });
}
