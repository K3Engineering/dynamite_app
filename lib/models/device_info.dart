import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Static identity of a connected sampler, read once per link from the BLE
/// Device Information service (0x180A) during post-connect setup.
///
/// Every field is independently best-effort: a failed read leaves that field
/// null and never fails the connection. [serial] is always null on web — the
/// Serial Number String characteristic (0x2A25) is on the Web Bluetooth GATT
/// blocklist.
class DeviceInfo {
  const DeviceInfo({
    this.manufacturer,
    this.model,
    this.serial,
    this.hardwareRev,
    this.firmwareRev,
  });

  /// Manufacturer Name String (0x2A29).
  final String? manufacturer;

  /// Model Number String (0x2A24) — the marketing name, e.g. "Dynamite
  /// Sampler Pro Mk1".
  final String? model;

  /// Serial Number String (0x2A25) — the eFuse MAC as 12 uppercase hex chars,
  /// matching the advertised name suffix ("DS XXXXXXXXXXXX"). Null on web.
  final String? serial;

  /// Hardware Revision String (0x2A27) — the board name, e.g. "v700P".
  final String? hardwareRev;

  /// Firmware Revision String (0x2A26) — `<board>|<git describe>`.
  final String? firmwareRev;

  // -- CSV session metadata (docs/csv-format-v1.md, the `device` block) -----

  /// The dynamite-csv `device` metadata block for a session recorded on the
  /// device known to the link as [name] with DIS identity [info] (null when
  /// the connect-time read never ran — every identity field is then null).
  /// Frozen onto the session row at recording start (the spec's
  /// recording-time snapshot requirement); [fromCsvDeviceMetadata] is the
  /// read side. Map order is the emission order (and matches the spec).
  /// `id` is the serial (the true hardware identity, unlike the platform
  /// device id) — null for sessions recorded on web, where 0x2A25 is
  /// blocklisted.
  static Map<String, Object?> toCsvDeviceMetadata({
    required String? name,
    required DeviceInfo? info,
  }) => {
    'name': (name == null || name.isEmpty) ? null : name,
    'id': info?.serial,
    'model': info?.model,
    'firmware': info?.firmwareRev,
    'manufacturer': info?.manufacturer,
  };

  /// Parse a session row's frozen `device` block (see [toCsvDeviceMetadata]).
  /// A malformed document, or non-string values in it, degrade to nulls —
  /// this is a display-only metadata path and must never throw. Unknown keys
  /// are dropped; unknown-to-this-app fields stay available to readers of
  /// the raw JSON.
  static Map<String, Object?> fromCsvDeviceMetadata(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map) {
        String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
        return {
          'name': s(decoded['name']),
          'id': s(decoded['id']),
          'model': s(decoded['model']),
          'firmware': s(decoded['firmware']),
          'manufacturer': s(decoded['manufacturer']),
        };
      }
    } catch (e) {
      debugPrint('Failed to parse session device metadata "$json": $e');
    }
    return toCsvDeviceMetadata(name: null, info: null);
  }
}
