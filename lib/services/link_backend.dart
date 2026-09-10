import 'dart:typed_data';

import '../models/device_flash.dart';

/// The device-side operations of the active link: the flash document round
/// trip, the Settings-namespace device name, and KVS frame routing.
/// Implemented by `GattLinkBackend` (a real link's KVS channel) and by the
/// simulated demo device directly — the link manager delegates to whichever
/// backs the active link rather than branching on which kind of link it is.
/// A real link whose KVS channel can't come up never finishes connecting
/// (see `BleLinkManager`), so a backend on an established link is always
/// usable.
abstract interface class LinkBackend {
  /// Write the load-cell slot keys (`lc0.cap`, ...): the only keys the app
  /// owns on the device. The backend SETs/DELs slot keys and leaves every
  /// other key — the factory board half, unknown keys — untouched.
  /// Throws on failure — the caller keeps its pending edits.
  Future<void> writeSlots(Map<String, String> lcKeys);

  /// Read the device KVS snapshot (connect-time load, save verification).
  /// Empty folders when the device holds no keys (an unprovisioned unit).
  /// Throws on failure.
  Future<KvsSnapshot> readKvsSnapshot();

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
