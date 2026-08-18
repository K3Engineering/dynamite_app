/// Wire framing for the device's key-value store (KVS) protocol, mirroring
/// `dynamite_sampler_api.h` / `user_kvs.cpp` in the firmware.
///
/// A command is written to the KVS characteristic as ASCII text:
/// `<CMD><FOLDER><DATA>` — e.g. `GETFch0.raw`, `SETUlc0.cap=200`, `IDXF1a`.
/// The device answers with a notification holding a status byte ('1' ok /
/// '0' failed), the request echoed verbatim, then '=' and the payload:
/// the value for GET, `key=typeHex` for IDX, empty for SET/DEL.
library;

import 'dart:convert';
import 'dart:typed_data';

const String kvsCmdGet = 'GET';
const String kvsCmdSet = 'SET';
const String kvsCmdDelete = 'DEL';
const String kvsCmdIndex = 'IDX';

/// Factory information, not factory-resettable: the board calibration.
/// (`DynaPersistent` partition, `Factory` namespace.)
const String kvsFolderFactory = 'F';

/// User information, not factory-resettable: the load cell data.
/// (`DynaPersistent` partition, `User` namespace.)
const String kvsFolderUser = 'U';

/// Settings, factory-resettable: device name, gain.
const String kvsFolderSettings = 'S';

/// The Settings-namespace key holding the user-assigned device name (value
/// grammar: docs/flash-schema-v1.md — enforced by `isValidDeviceName` in
/// the model layer, not here).
const String kvsKeyDeviceName = 'device_name';

/// Firmware limits (user_kvs.cpp): keys up to 15 chars, values up to 128
/// chars, and the whole request frame up to 240 bytes.
const int kvsMaxKeyLength = 15;
const int kvsMaxValueLength = 128;
const int kvsMaxFrameLength = 240;

/// The NVS value type firmware reports for string entries in IDX payloads
/// (NVS_TYPE_STR from nvs.h), as hex text.
const String kvsNvsTypeStrHex = '21';

void _checkKey(String key) {
  if (key.isEmpty || key.length > kvsMaxKeyLength || key.contains('=')) {
    throw ArgumentError.value(
      key,
      'key',
      'need 1..$kvsMaxKeyLength chars, no =',
    );
  }
}

String encodeKvsGet(String folder, String key) {
  _checkKey(key);
  return '$kvsCmdGet$folder$key';
}

String encodeKvsSet(String folder, String key, String value) {
  _checkKey(key);
  if (value.isEmpty || value.length > kvsMaxValueLength) {
    throw ArgumentError.value(
      value,
      'value',
      'need 1..$kvsMaxValueLength chars',
    );
  }
  return '$kvsCmdSet$folder$key=$value';
}

String encodeKvsDelete(String folder, String key) {
  _checkKey(key);
  return '$kvsCmdDelete$folder$key';
}

/// IDX takes the entry number as hex text (firmware parses base 16).
String encodeKvsIndex(String folder, int index) =>
    '$kvsCmdIndex$folder${index.toRadixString(16)}';

/// One parsed KVS response (see [parseKvsResponse] for the frame layout).
class KvsResponse {
  const KvsResponse({required this.ok, required this.payload});

  /// The status byte: true for '1' (command succeeded).
  final bool ok;

  /// Everything after the echoed request and '='; '' for failed commands
  /// and for commands without a payload (SET/DEL).
  final String payload;
}

/// Parse the notification frame answering [request]. The echo must match
/// the request verbatim — a mismatch means the frame answers some other
/// command (or is not a KVS response at all), which is a protocol error.
KvsResponse parseKvsResponse(String request, Uint8List frame) {
  final requestBytes = utf8.encode(request);
  // Smallest frame: status + echo (+'=' on success).
  if (frame.length < 1 + requestBytes.length) {
    throw FormatException(
      'KVS frame too short: ${frame.length} B for "$request"',
    );
  }
  for (var i = 0; i < requestBytes.length; ++i) {
    if (frame[1 + i] != requestBytes[i]) {
      throw FormatException('KVS echo mismatch for "$request"');
    }
  }
  switch (frame[0]) {
    case 0x30: // '0'
      return const KvsResponse(ok: false, payload: '');
    case 0x31: // '1'
      if (frame.length < 1 + requestBytes.length + 1 ||
          frame[1 + requestBytes.length] != 0x3D /* = */ ) {
        throw const FormatException('KVS frame missing payload separator');
      }
      return KvsResponse(
        ok: true,
        payload: utf8.decode(
          frame.sublist(1 + requestBytes.length + 1),
          allowMalformed: true,
        ),
      );
    default:
      throw FormatException('KVS bad status byte: ${frame[0]}');
  }
}

/// Parse an IDX payload (`key=typeHex`) into its entry. A key can never
/// contain '=' (SET splits at the first one), so the type rides after the
/// LAST '='. Returns null when the payload is malformed.
(String key, int nvsType)? parseKvsIndexPayload(String payload) {
  final eq = payload.lastIndexOf('=');
  if (eq <= 0 || eq == payload.length - 1) return null;
  final type = int.tryParse(payload.substring(eq + 1), radix: 16);
  if (type == null) return null;
  return (payload.substring(0, eq), type);
}
