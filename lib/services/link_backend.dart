import 'dart:typed_data';

import '../models/device_info.dart';

/// The device-side operations of the active link: the flash document round
/// trip (see `RigFlashTransport`), the Settings-namespace device name, and
/// KVS frame routing. Implemented by `GattLinkBackend` (a real link's KVS
/// channel) and by the simulated demo device directly — the link manager
/// delegates to whichever backs the active link rather than branching on
/// which kind of link it is. Null while a link is up without a usable KVS
/// channel (subscription failed during setup); the manager's null checks
/// surface the same failures they always did.
abstract interface class LinkBackend {
  /// Write a serialized `DeviceFlash` document.
  /// Throws on failure — the caller keeps its pending edits.
  Future<void> writeFlashDoc(String doc);

  /// Read the flash document back (connect-time load, save verification).
  /// Throws on failure.
  Future<String?> readFlashDoc();

  /// Persist the Settings-namespace device name (null clears it — the
  /// device reverts to its factory name). True when the device accepted
  /// the change.
  Future<bool> storeDeviceName(String? name);

  /// The Settings-namespace device name, or null when unset.
  /// Throws on transport failure.
  Future<String?> readDeviceName();

  /// Route a KVS notification frame to the outstanding command. Unreachable
  /// on backends without a GATT notification path — throws there.
  void handleKvsFrame(Uint8List data);

  /// The link is going away: stop the feed / abort in-flight commands.
  void dispose();
}

/// What the manager needs to bring up a simulated (non-BLE) link: a
/// [LinkBackend] plus the pieces a real link collects as it comes up —
/// identity, the connect-time flash document, PGA gains, and the ADC feed
/// itself.
abstract interface class SimulatedLink extends LinkBackend {
  /// The synthetic device id (never a real BLE id).
  String get id;

  /// The display name before any stored name lands.
  String get displayName;

  /// The stored name as the connect should present it (null = unset).
  String? get storedName;

  /// The simulated identity (real links read theirs from the Device
  /// Information service in post-connect setup).
  DeviceInfo? get identity;

  /// The flash document served at connect time. Reads after a "Save to
  /// device" round-trip return whatever was last written.
  String get flashDoc;

  /// Per-channel PGA gains served alongside the flash doc (the analogue
  /// of the GAIN-register readback on real links).
  List<double>? get pgaGains;

  /// Start the simulated ADC feed, delivered like GATT notifications.
  /// The matching stop is [LinkBackend.dispose].
  void startFeed(void Function(Uint8List) onData);
}
