/// The device-name grammar (docs/flash-schema-v1.md): the Settings-namespace
/// name the user can write to the device.
library;

/// Device-name length cap in chars (= bytes; the grammar is ASCII-only).
/// 29 always fits the BLE advertising scan-response payload (31 B minus
/// the 2-byte AD header), the GAP name buffer, and the KVS value limit.
const int deviceNameMaxLength = 29;

final RegExp _deviceNamePattern = RegExp(
  r"^[A-Za-z0-9][A-Za-z0-9 ._()'-]{0,28}$",
);

/// Whether [name] is a legal device name (docs/flash-schema-v1.md).
/// Callers trim first — surrounding whitespace is input hygiene, never
/// part of the stored value; an empty (post-trim) input means "clear the
/// name" (a DEL), which this check does not cover.
bool isValidDeviceName(String name) => _deviceNamePattern.hasMatch(name);
