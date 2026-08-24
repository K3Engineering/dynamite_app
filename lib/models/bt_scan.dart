/// App-level Bluetooth link/scan/adapter types. [BleLinkManager] maps
/// universal_ble's `BleDevice`/`AvailabilityState` into these at its
/// boundary, so nothing outside the service layer names the plugin's types —
/// and widgets that only need the enums don't pull in the manager.
library;

/// Lifecycle of a single device's BLE link.
///
/// This is intentionally a *per-device* concept even though, today, the app
/// only tracks one link at a time (see [BleLinkManager]).
enum BtLinkState {
  /// No connection to this device; it may or may not be in the discovered list.
  idle,

  /// A `connect()` call is outstanding; not yet usable.
  connecting,

  /// The GATT link is up but post-connect setup is still running the first of
  /// its three stages: MTU negotiation (native only) and service discovery.
  /// NOT yet usable — no data is flowing. The UI shows "Setting up…" here.
  connected,

  /// Post-connect setup's second stage: services are discovered; the board
  /// constants (device identity, the ADC's config/GAIN readback, and the
  /// connect-time flash document read over KVS) are being read. Still NOT
  /// usable. The UI shows "Reading board constants…" here. This stage gates
  /// on the reads COMPLETING, never on their content: a board with missing
  /// or invalid constants still advances (the live UI degrades to raw
  /// counts there — refusing the link would hide even those).
  readingConstants,

  /// Post-connect setup's third stage: the board constants are in and the
  /// ADC feed subscription (enabling notifications) is in progress. Still
  /// NOT usable. The UI shows "Starting data stream…" here.
  /// The link advances to [streaming] only once the subscription succeeds, or
  /// is torn down on failure.
  subscribing,

  /// Fully set up: services discovered and the ADC feed subscription is active,
  /// so data is flowing. This is the single "usable / connected" state.
  streaming,

  /// A `disconnect()` was requested; awaiting the connection callback (or the
  /// disconnect() timeout). Connect must stay blocked while in this state so we
  /// never issue a connect against a half-torn-down link.
  disconnecting,
}

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
