/// App-level Bluetooth link/scan/adapter types.
library;

/// Lifecycle of a single device's BLE link.
enum BtLinkState {
  /// No connection to this device; it may or may not be in the discovered list.
  idle,

  /// A `connect()` call is outstanding; not yet usable.
  connecting,

  /// GATT link up; post-connect setup is running MTU negotiation (native only)
  /// and service discovery. Not yet usable.
  connected,

  /// Post-connect setup reading board constants (device identity, ADC config/
  /// GAIN, and the flash document). An unreadable ADC config or failed KVS
  /// bring-up tears the link down; invalid known flash content becomes an
  /// `InvalidBoardCalibration` and the device streams raw counts.
  readingConstants,

  /// Post-connect setup subscribing to the ADC feed. Advances to [streaming]
  /// once the subscription succeeds, or is torn down on failure.
  subscribing,

  /// Fully set up and usable: the ADC feed subscription is active.
  streaming,

  /// A `disconnect()` was requested; awaiting the callback or its timeout.
  disconnecting,
}

/// Adapter availability, one-to-one with universal_ble's `AvailabilityState`.
enum BtAvailability {
  poweredOn,
  poweredOff,
  unknown,
  resetting,
  unsupported,
  unauthorized,
}

/// A scanned device: identity, name, and the freshest advert's RSSI and time.
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

  /// RSSI (dBm) of the freshest advert; null on web.
  final int? rssi;

  /// Advert receipt time (ms since epoch), the freshness of [rssi]; null on
  /// web.
  final int? timestamp;
}
