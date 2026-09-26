import 'package:meta/meta.dart';

/// Static identity of a connected sampler, read once per link from the BLE
/// Device Information service (0x180A) during post-connect setup.
///
/// Firmware publishes every field (see setupDeviceInfo() in ble_proc.cpp),
/// so a failed read is a link defect and fails the setup — there are no
/// best-effort nulls. [serial] is the one legitimately absent field: the
/// Serial Number String characteristic (0x2A25) is on the Web Bluetooth
/// GATT blocklist, so it is null on web.
@immutable
class DeviceInfo {
  const DeviceInfo({
    required this.manufacturer,
    required this.model,
    this.serial,
    required this.hardwareRev,
    required this.firmwareRev,
  });

  /// Manufacturer Name String (0x2A29).
  final String manufacturer;

  /// Model Number String (0x2A24) — the marketing name, e.g. "Dynamite
  /// Sampler Pro Mk1".
  final String model;

  /// Serial Number String (0x2A25) — the eFuse MAC as 12 uppercase hex chars,
  /// matching the advertised name suffix ("DS XXXXXXXXXXXX"). Null on web.
  final String? serial;

  /// Hardware Revision String (0x2A27) — the board name, e.g. "v700P".
  final String hardwareRev;

  /// Firmware Revision String (0x2A26) — `<board>|<git describe>`.
  final String firmwareRev;
}
