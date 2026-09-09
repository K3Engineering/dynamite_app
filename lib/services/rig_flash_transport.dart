/// The piece of the BLE stack `RigState` needs: which device is connected,
/// and a way to persist load-cell slots to it. Implemented by
/// `BleLinkManager` (the demo device applies slot edits to its in-memory
/// doc; real devices write per-key diffs over the device KVS — see
/// `KvsFlashTransport.writeSlots`).
library;

abstract interface class RigFlashTransport {
  /// Empty string when no device is connected.
  String get connectedDeviceId;

  /// Display name of the connected device ('' when none).
  String get connectedDeviceName;

  /// Write the load-cell slot keys (`lc0.cap`, ...) to the connected
  /// device: the only keys the app owns there. The transport SETs/DELs
  /// slot keys and leaves every other key — the factory board half,
  /// unknown keys — untouched. Throws on failure — the caller keeps its
  /// pending edits.
  Future<void> writeSlots(Map<String, String> lcKeys);

  /// Read the flash document back from the connected device (save
  /// verification). Throws on failure or when no device is connected.
  Future<String> readFlashDoc();
}
