import 'package:meta/meta.dart';

/// Static identity of a connected sampler, read once per link from the BLE
/// Device Information service (0x180A) during post-connect setup.
///
/// Current firmware publishes every field (see setupDeviceInfo() in
/// ble_proc.cpp), so a failed read is a link defect and fails the setup.
/// [serial] is on the Web Bluetooth GATT blocklist (0x2A25) and null on web;
/// [frameworkRev] is null when connecting to firmware that predates 0x2A28.
@immutable
class const DeviceInfo({
  /// Manufacturer Name String (0x2A29).
  required final String manufacturer,

  /// Model Number String (0x2A24) — the marketing name, e.g. "Dynamite
  /// Sampler Pro Mk1".
  required final String model,

  /// Serial Number String (0x2A25) — the eFuse MAC as 12 uppercase hex chars,
  /// matching the advertised name suffix ("DS XXXXXXXXXXXX"). Null on web.
  final String? serial,

  /// Hardware Revision String (0x2A27) — the board name, e.g. "v700P".
  required final String hardwareRev,

  /// Firmware Revision String (0x2A26) — the build's git describe, as
  /// published by the firmware's [onFwVer] (`v0.3.2`, `0.2.0-14-g8bfc247`).
  required final String firmwareRev,

  /// Software Revision String (0x2A28) — the ESP-IDF version, e.g.
  /// "ESP-IDF v6.1". Null on firmware predating this characteristic.
  // TODO(compat): Make mandatory once deployed units have Software Revision.
  final String? frameworkRev,
});
