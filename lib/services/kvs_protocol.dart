/// Wire framing for the device's key-value store (KVS) protocol, mirroring the
/// firmware. A command is written as ASCII `<CMD><FOLDER><DATA>`; the device
/// answers with a status byte, the request echoed, and — on success only — '='
/// and the payload. Every command gets exactly one answer.
library;

import 'dart:convert';
import 'dart:typed_data';

const String kvsCmdGet = 'GET';
const String kvsCmdSet = 'SET';
const String kvsCmdDelete = 'DEL';
const String kvsCmdIndex = 'IDX';

/// Factory information, not factory-resettable: the board calibration. The app
/// NEVER writes this folder; [_checkWritableFolder] enforces it at the SET/DEL
/// choke point.
const String kvsFolderFactory = 'F';

/// User information: the load cell data, the one half the app writes.
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

/// The app never writes the Factory partition; encoders are the choke point
/// every write passes through.
void _checkWritableFolder(String folder) {
  if (folder == kvsFolderFactory) {
    throw ArgumentError.value(
      folder,
      'folder',
      'the app never writes the Factory partition',
    );
  }
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

/// The answer's status byte.
enum KvsStatus {
  /// '1' — success; the payload follows the echoed request and '='.
  ok,

  /// '0' — the request's fault: GET/DEL no such key, SET a malformed
  /// frame, IDX past the last entry (this is how key iteration ends).
  rejected,

  /// 'B' — the device is locked (ADC feed streaming); the request was not
  /// processed. Retrying, if at all, is the caller's policy.
  busy,

  /// 'E' — the device's storage layer failed. Never a missing key; a
  /// mid-iteration error is not end-of-keys.
  error,
}

/// The device answered 'B' (busy, streaming).
class KvsBusyException implements Exception {
  @override
  String toString() => 'KVS busy: the device is locked (streaming)';
}

/// The device answered 'E' (storage-layer failure).
class KvsDeviceException implements Exception {
  @override
  String toString() => 'KVS device error (a storage-layer failure)';
}

/// One parsed KVS response (see [parseKvsResponse] for the frame layout).
class KvsResponse {
  const KvsResponse({required this.status, required this.payload});

  /// The status byte the device answered with.
  final KvsStatus status;

  /// Everything after the echoed request and '='; '' for non-ok answers
  /// and for commands without a payload (SET/DEL).
  final String payload;

  /// Throws on [KvsStatus.busy] and [KvsStatus.error]; ok and rejected settle.
  void throwIfBusyOrError() {
    switch (status) {
      case KvsStatus.ok:
      case KvsStatus.rejected:
        break;
      case KvsStatus.busy:
        throw KvsBusyException();
      case KvsStatus.error:
        throw KvsDeviceException();
    }
  }
}

/// Parse the frame answering [request]. Null when it is a well-formed answer to
/// some OTHER command (stale; drop it). Throws [FormatException] on a garbled
/// frame or non-UTF-8 payload — undecodable bytes mean the link can't be
/// trusted.
KvsResponse? parseKvsResponse(String request, Uint8List frame) {
  final requestBytes = utf8.encode(request);
  final status = switch (frame.isEmpty ? -1 : frame[0]) {
    0x31 => KvsStatus.ok, // '1'
    0x30 => KvsStatus.rejected, // '0'
    0x42 => KvsStatus.busy, // 'B'
    0x45 => KvsStatus.error, // 'E'
    final other => throw FormatException('KVS bad status byte: $other'),
  };
  // Exact-echo match, prefix-free both ways so a stale answer to a longer or
  // shorter command can't settle this pending one.
  if (_bytesAt(frame, 1, requestBytes)) {
    if (status == KvsStatus.ok &&
        frame.length > 1 + requestBytes.length &&
        frame[1 + requestBytes.length] == 0x3D /* = */ ) {
      return KvsResponse(
        status: status,
        payload: utf8.decode(frame.sublist(1 + requestBytes.length + 1)),
      );
    }
    if (status != KvsStatus.ok && frame.length == 1 + requestBytes.length) {
      return KvsResponse(status: status, payload: '');
    }
  }
  // Not this command's answer: well-formed means stale (drop), anything else
  // is garbage (throw).
  if (!_isWellFormedKvsFrame(frame)) {
    throw FormatException('KVS garbled frame (${frame.length} B)');
  }
  return null;
}

/// Shaped like a KVS answer to SOME command: separates a stale frame (drop)
/// from garbage on the wire (throw).
bool _isWellFormedKvsFrame(Uint8List frame) {
  // <Status:1><Cmd:3><Folder:1><Data…>; the data may be empty on a rejection.
  if (frame.length < 5) return false;
  final knownStatus =
      frame[0] == 0x31 /* 1 */ ||
      frame[0] == 0x30 /* 0 */ ||
      frame[0] == 0x42 /* B */ ||
      frame[0] == 0x45 /* E */;
  final knownCommand =
      _bytesAt(frame, 1, utf8.encode(kvsCmdGet)) ||
      _bytesAt(frame, 1, utf8.encode(kvsCmdSet)) ||
      _bytesAt(frame, 1, utf8.encode(kvsCmdDelete)) ||
      _bytesAt(frame, 1, utf8.encode(kvsCmdIndex));
  final knownFolder =
      frame[4] == 0x46 /* F */ ||
      frame[4] == 0x55 /* U */ ||
      frame[4] == 0x53 /* S */;
  if (!(knownStatus && knownCommand && knownFolder)) return false;
  final hasSeparator = frame.indexOf(0x3D /* = */, 5) >= 0;
  return (frame[0] == 0x31) == hasSeparator;
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
/// LAST '='. Throws [FormatException] on a malformed payload.
(String key, int nvsType) parseKvsIndexPayload(String payload) {
  final eq = payload.lastIndexOf('=');
  final type = eq <= 0 || eq == payload.length - 1
      ? null
      : int.tryParse(payload.substring(eq + 1), radix: 16);
  if (type == null) {
    throw FormatException('malformed IDX payload: "$payload"');
  }
  return (payload.substring(0, eq), type);
}
