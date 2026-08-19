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

/// The folder a flash-document key lives in: load cell keys in User, board
/// calibration and metadata in Factory. (Settings holds name/gain — never
/// document keys.)
String kvsFolderForKey(String key) =>
    key.startsWith('lc') ? kvsFolderUser : kvsFolderFactory;

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

/// The app never writes the Factory partition (board calibration is
/// read-only to it — factory tooling owns those keys). This is a core
/// assumption the document-diff saver currently satisfies only implicitly,
/// so every SET/DEL frame asserts it here at the choke point.
void _checkWritableFolder(String folder) {
  assert(
    folder != kvsFolderFactory,
    'the app never writes the Factory partition',
  );
}

String encodeKvsSet(String folder, String key, String value) {
  _checkWritableFolder(folder);
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
  _checkWritableFolder(folder);
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

/// Parse the notification frame answering [request].
///
/// Returns null when the frame is a well-formed answer to some OTHER command
/// — a stale frame whose own command already timed out; the caller drops it
/// and the live command keeps awaiting its own reply. Throws
/// [FormatException] on a garbled frame, which fails the live command:
/// garbage on the wire means the link can't be trusted.
KvsResponse? parseKvsResponse(String request, Uint8List frame) {
  final requestBytes = utf8.encode(request);
  if (frame.isEmpty || (frame[0] != 0x30 && frame[0] != 0x31)) {
    throw FormatException(
      'KVS bad status byte: ${frame.isEmpty ? -1 : frame[0]}',
    );
  }
  final success = frame[0] == 0x31; // '1'
  // Exact-echo match at the echo's fixed position: '<status><request>' for a
  // failure, '<status><request>=<payload>' for a success. Prefix-free both
  // ways: a stale '0GETFabcX' must not settle a pending GETFabc, nor a stale
  // '0GETFabc' a pending GETFabcX.
  if (_bytesAt(frame, 1, requestBytes)) {
    if (success &&
        frame.length > 1 + requestBytes.length &&
        frame[1 + requestBytes.length] == 0x3D /* = */ ) {
      return KvsResponse(
        ok: true,
        payload: utf8.decode(
          frame.sublist(1 + requestBytes.length + 1),
          allowMalformed: true,
        ),
      );
    }
    if (!success && frame.length == 1 + requestBytes.length) {
      return const KvsResponse(ok: false, payload: '');
    }
  }
  // Not this command's answer: well-formed means stale (drop), anything else
  // is garbage (throw).
  if (!_isWellFormedKvsFrame(frame)) {
    throw FormatException('KVS garbled frame (${frame.length} B)');
  }
  return null;
}

/// Shaped like a KVS answer to SOME command: known command word, known
/// folder letter, and (successes only) a payload separator — the firmware
/// writes '=' even for an empty payload. Separates a stale frame (drop)
/// from garbage on the wire (throw).
bool _isWellFormedKvsFrame(Uint8List frame) {
  // <Status:1><Cmd:3><Folder:1><Data…>; the data may be empty on a rejection.
  if (frame.length < 5) return false;
  final knownCommand =
      _bytesAt(frame, 1, utf8.encode(kvsCmdGet)) ||
      _bytesAt(frame, 1, utf8.encode(kvsCmdSet)) ||
      _bytesAt(frame, 1, utf8.encode(kvsCmdDelete)) ||
      _bytesAt(frame, 1, utf8.encode(kvsCmdIndex));
  final knownFolder =
      frame[4] == 0x46 /* F */ ||
      frame[4] == 0x55 /* U */ ||
      frame[4] == 0x53 /* S */;
  if (!(knownCommand && knownFolder)) return false;
  if (frame[0] == 0x31 && frame.indexOf(0x3D /* = */, 5) < 0) return false;
  return true;
}

bool _bytesAt(Uint8List frame, int offset, List<int> bytes) {
  if (frame.length < offset + bytes.length) return false;
  for (var i = 0; i < bytes.length; ++i) {
    if (frame[offset + i] != bytes[i]) return false;
  }
  return true;
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
