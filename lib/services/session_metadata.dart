import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/device_info.dart';

/// The session-row `device` metadata block: the connected device's identity,
/// frozen onto the session row at recording start (the CSV format's
/// recording-time snapshot requirement — docs/csv-format-v1.md). Built from
/// the link's advertised/stored [name] and the DIS identity [info] (null
/// when the connect-time read never ran — every identity field is then
/// null). Map order matches the CSV spec's emission order.
/// `id` is the serial (the true hardware identity, unlike the platform
/// device id) — null for sessions recorded on web, where 0x2A25 is
/// blocklisted.
Map<String, Object?> toSessionDeviceMetadata({
  required String? name,
  required DeviceInfo? info,
}) => {
  'name': (name == null || name.isEmpty) ? null : name,
  'id': info?.serial,
  'model': info?.model,
  'hardware_rev': info?.hardwareRev,
  'firmware': info?.firmwareRev,
  'manufacturer': info?.manufacturer,
};

/// Parse a session row's frozen `device` block (see [toSessionDeviceMetadata]).
/// A malformed document, or non-string values in it, degrade to nulls —
/// this is a display-only metadata path and must never throw. Unknown keys
/// are dropped; unknown-to-this-app fields stay available to readers of
/// the raw JSON.
Map<String, Object?> fromSessionDeviceMetadata(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is Map) {
      String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
      return {
        'name': s(decoded['name']),
        'id': s(decoded['id']),
        'model': s(decoded['model']),
        'hardware_rev': s(decoded['hardware_rev']),
        'firmware': s(decoded['firmware']),
        'manufacturer': s(decoded['manufacturer']),
      };
    }
  } catch (e) {
    debugPrint('Failed to parse session device metadata "$json": $e');
  }
  return toSessionDeviceMetadata(name: null, info: null);
}

/// Parse a JSON-encoded list column into exactly [count] entries: entry i is
/// [convert] applied to the i-th decoded element, or [fallback] when the
/// document is malformed, shorter than [count], or the element fails to
/// convert. For display-only columns only (channel labels, visible
/// channels): a corrupt value degrades to defaults instead of throwing.
/// Measurement columns (tares, calibration, gaps) do NOT use this — they
/// parse strictly at the SessionStorage boundary, where damage sets a
/// [SessionDamage] flag rather than silently fabricating defaults.
List<T> parseJsonColumn<T>(
  String json,
  int count, {
  required T Function(Object? decoded) convert,
  required T Function(int index) fallback,
}) {
  List<dynamic>? parsed;
  try {
    final decoded = jsonDecode(json);
    if (decoded is List) parsed = decoded;
  } catch (e) {
    debugPrint('Failed to parse session metadata "$json": $e');
  }
  T entry(int i) {
    if (parsed == null || i >= parsed.length) return fallback(i);
    try {
      return convert(parsed[i]);
    } catch (_) {
      return fallback(i);
    }
  }

  return [for (int i = 0; i < count; i++) entry(i)];
}
