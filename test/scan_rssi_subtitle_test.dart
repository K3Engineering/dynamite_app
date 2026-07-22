import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/screens/devices_tab.dart' show scanRssiSubtitle;

/// Tests for [scanRssiSubtitle], the inactive device row's scan-RSSI text.
/// The web case is the point of the mapping: Web Bluetooth can never deliver
/// a scan RSSI (requestDevice() has none, watchAdvertisements is abandoned),
/// so the row drops the slot entirely instead of showing a permanent
/// "RSSI: --" placeholder for a reading that can never exist.
void main() {
  test('a reading renders as dBm on any platform', () {
    expect(scanRssiSubtitle(-58, supportsScanRssi: true), 'RSSI: -58 dBm');
    expect(scanRssiSubtitle(-58, supportsScanRssi: false), 'RSSI: -58 dBm');
  });

  test('no reading yet on an RSSI-capable platform is a transient placeholder', () {
    expect(scanRssiSubtitle(null, supportsScanRssi: true), 'RSSI: --');
  });

  test('no reading possible (web) drops the RSSI slot entirely', () {
    expect(scanRssiSubtitle(null, supportsScanRssi: false), isNull);
  });
}
