/// The piece of the BLE stack `RigState` needs: which device is connected,
/// and a way to write the whole flash document back to it. Implemented by
/// `BleLinkManager` (demo device mutates an in-memory doc; real devices go
/// through the device KVS — see `KvsFlashTransport`).
library;

abstract interface class RigFlashTransport {
  /// Empty string when no device is connected.
  String get connectedDeviceId;

  /// Display name of the connected device ('' when none).
  String get connectedDeviceName;

  /// Write a serialized flash document to the connected device.
  /// Throws on failure — the caller keeps its pending edits.
  Future<void> writeFlashDoc(String doc);

  /// Read the flash document back from the connected device (save
  /// verification). Null on failure or when no device is connected.
  Future<String?> readFlashDoc();
}
