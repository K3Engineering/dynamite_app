/// Wire framing for the device's key-value store (KVS) protocol, mirroring
/// `dynamite_sampler_api.h` / `user_kvs.cpp` in the firmware.
///
/// A command is written to the KVS characteristic as ASCII text:
/// `<CMD><FOLDER><DATA>` — e.g. `GETFch0.raw`, `SETUlc0.cap=200`, `IDXF1a`.
/// The device answers with a notification holding a status byte (see
/// [KvsStatus]), the request echoed verbatim, then — on success only —
/// '=' and the payload: the value for GET, `key=typeHex` for IDX, empty
/// for SET/DEL. Every command gets exactly one answer, so a command whose
/// answer never arrives means the link is broken.
library;

import 'dart:convert';
import 'dart:typed_data';

const String kvsCmdGet = 'GET';
const String kvsCmdSet = 'SET';
const String kvsCmdDelete = 'DEL';
const String kvsCmdIndex = 'IDX';

/// Factory information, not factory-resettable: the board calibration.
/// (`DynaPersistent` partition, `Factory` namespace.) The app NEVER writes
/// this folder — the board half of the flash document is read-only to it
/// (factory tooling owns those keys). Call sites pass folder literals, and
/// [_checkWritableFolder] throws at the SET/DEL choke point so a future
/// caller can't slip a Factory write past the design.
const String kvsFolderFactory = 'F';

/// User information, not factory-resettable: the load cell data — the one
/// document half the app writes.
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

/// The app never writes the Factory partition (see [kvsFolderFactory]).
/// This is a core assumption the slot-key writer satisfies by construction,
/// but the encoders are the choke point every write passes through, so the
/// guard lives here.
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

/// The answer's status byte. 'B' is how the firmware device lock answers
/// while the ADC feed streams (nothing is dropped silently); 'E' is a
/// storage-layer failure on the device.
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

/// The device answered 'B' (busy): locked while the ADC feed streams.
class KvsBusyException implements Exception {
  @override
  String toString() => 'KVS busy: the device is locked (streaming)';
}

/// The device answered 'E': a storage-layer failure on the device.
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

  /// [KvsStatus.busy] and [KvsStatus.error] answers are command failures,
  /// not data — throw them. Ok and rejected answers settle normally.
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

/// Parse the notification frame answering [request].
///
/// Returns null when the frame is a well-formed answer to some OTHER command
/// — a stale frame whose own command already timed out; the caller drops it
/// and the live command keeps awaiting its own reply. Throws
/// [FormatException] on a garbled frame (an unknown status byte included)
/// OR on payload bytes that aren't valid UTF-8 (calibration data is ASCII
/// text; undecodable bytes passing the frame checks can only be
/// firmware/wire corruption — replacing them with U+FFFD would let a
/// corrupted read masquerade as an uncalibrated board). Either failure
/// fails the live command: bytes the protocol can't decode mean the link
/// can't be trusted.
KvsResponse? parseKvsResponse(String request, Uint8List frame) {
  final requestBytes = utf8.encode(request);
  final status = switch (frame.isEmpty ? -1 : frame[0]) {
    0x31 => KvsStatus.ok, // '1'
    0x30 => KvsStatus.rejected, // '0'
    0x42 => KvsStatus.busy, // 'B'
    0x45 => KvsStatus.error, // 'E'
    final other => throw FormatException('KVS bad status byte: $other'),
  };
  // Exact-echo match at the echo's fixed position: '<status><request>' for a
  // non-success answer, '<status><request>=<payload>' for a success.
  // Prefix-free both ways: a stale '0GETFabcX' must not settle a pending
  // GETFabc, nor a stale '0GETFabc' a pending GETFabcX.
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

/// Shaped like a KVS answer to SOME command: known status byte, known
/// command word, known folder letter, and the payload separator exactly
/// where the status demands it — successes carry '=' (even with an empty
/// payload), the other statuses never do. Separates a stale frame (drop)
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
