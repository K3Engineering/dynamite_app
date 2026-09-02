import '../models/device_info.dart';

/// The session-row `device` metadata block: the connected device's identity,
/// frozen onto the session row at recording start (the CSV format's
/// recording-time snapshot requirement — csv-format-v1.md). Built from
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
