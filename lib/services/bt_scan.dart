/// App-level Bluetooth scan/adapter types. [BleLinkManager] maps
/// universal_ble's `BleDevice`/`AvailabilityState` into these at its
/// boundary, so nothing outside the service layer names the plugin's types.
library;

/// Adapter availability. One-to-one with universal_ble's `AvailabilityState`
/// (same names; the manager converts with `BtAvailability.values.byName`).
enum BtAvailability {
  poweredOn,
  poweredOff,
  unknown,
  resetting,
  unsupported,
  unauthorized,
}

/// A scanned device as the app knows it: identity, display name, and the
/// freshest advert's RSSI and receipt time.
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.deviceId,
    this.name,
    this.rssi,
    this.timestamp,
  });

  final String deviceId;

  /// Advertised name; null when no advert carried one (plain ADV packets
  /// often omit it — it may only ride in the SCAN_RSP).
  final String? name;

  /// Signal strength of the freshest advert (dBm); null on web, where scan
  /// results carry no advert data.
  final int? rssi;

  /// Advert receipt time (ms since epoch): the freshness of [rssi]. Null on
  /// web, where no advertisement data exists.
  final int? timestamp;
}
