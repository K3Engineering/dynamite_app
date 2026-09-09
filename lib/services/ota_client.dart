import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ota_protocol.dart';

/// A flash session failure with plain-language copy for the UI. Covers
/// device-level refusals (NAKs), protocol surprises, and reply timeouts —
/// transport writes throw whatever UniversalBle throws.
class OtaFlashException implements Exception {
  const OtaFlashException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// OTA flash client for the firmware's OTA GATT service (see ble_ota.cpp).
/// Single-session: one [flash] per instance, and the owning transport tears
/// it down afterwards via [abort] (mirroring [KvsClient]'s per-link shape).
///
/// The wire sequence: declared size -> [otaReadyReply] -> REQUEST ->
/// ACK/NAK -> image bytes on the Data characteristic -> DONE -> ACK/NAK,
/// after which the device restarts on its own (~0.5 s later). Two rules
/// come from the reference client (firmware/ota_update.py):
///
///  * Data chunks MUST use write-with-response: the firmware applies each
///    chunk inside the write handler and the ATT ack is the flow control.
///    Chunking to write-without-response would silently overflow it.
///  * The final DONE is written WITHOUT response — a with-response DONE
///    hangs. TODO: re-verify against current firmware; drop this if fixed.
class OtaClient {
  OtaClient({
    required this.writeControl,
    required this.writeData,
    this.chunkSize = 244,
    this.ackTimeout = const Duration(seconds: 30),
  });

  /// Write the Control characteristic. [withoutResponse] is used only for
  /// the final DONE (see class doc).
  final Future<void> Function(Uint8List bytes, {bool withoutResponse})
  writeControl;

  /// Write one image chunk to the Data characteristic (with-response).
  final Future<void> Function(Uint8List bytes) writeData;

  /// Image chunk size: min(negotiated MTU - 3, 244), like the reference
  /// client. The 244 cap also fits platforms that never report an MTU
  /// (web) but negotiate 247 behind the scenes.
  final int chunkSize;

  /// Upper bound on one Control round trip (accept-size, accept-update,
  /// finalize). Generous: the finalize wait covers the device erasing the
  /// rest of the slot and digest-checking a ~1 MB image.
  final Duration ackTimeout;

  bool _aborted = false;
  Completer<Uint8List>? _waiting;

  /// Entry point for Control notifications (routed here by the link
  /// manager). A notification settles only the live wait; the device sends
  /// exactly one reply per handshake step and none during Data writes.
  void handleNotification(Uint8List data) {
    final waiting = _waiting;
    if (waiting == null || waiting.isCompleted) return;
    waiting.complete(data);
  }

  /// Fail the live wait, if any. Called at session teardown; the client is
  /// spent afterwards.
  void abort() {
    _aborted = true;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(StateError('OTA session aborted'));
    }
  }

  /// Flash [image] onto the device's next OTA slot. Returns once the device
  /// has accepted the image (it then reboots into it on its own);
  /// [onProgress] reports cumulative bytes written. Throws
  /// [OtaFlashException] on any device refusal or protocol failure.
  Future<void> flash({
    required Uint8List image,
    void Function(int sentBytes)? onProgress,
  }) async {
    await writeControl(encodeOtaFileSize(image.length));
    await _expectReply(otaReadyReply, 'accept the update size');

    await writeControl(Uint8List.fromList(const [otaRequestOpcode]));
    final request = await _reply('accept the update');
    if (request == otaRequestNak) {
      throw const OtaFlashException('The device declined to start.');
    }
    if (request != otaRequestAck) {
      throw OtaFlashException(_unexpected(request, 'accept the update'));
    }

    for (var offset = 0; offset < image.length; offset += chunkSize) {
      if (_aborted) throw StateError('OTA session aborted');
      final end = offset + chunkSize;
      await writeData(
        image.sublist(offset, end > image.length ? image.length : end),
      );
      onProgress?.call(end > image.length ? image.length : end);
    }

    // See class doc: DONE is sent without response on purpose.
    await writeControl(
      Uint8List.fromList(const [otaDoneOpcode]),
      withoutResponse: true,
    );
    final done = await _reply('finalize the update');
    if (done == otaDoneNak) {
      throw const OtaFlashException(
        'The device rejected the image (integrity check failed).',
      );
    }
    if (done != otaDoneAck) {
      throw OtaFlashException(_unexpected(done, 'finalize the update'));
    }
  }

  String _unexpected(int got, String what) =>
      'Unexpected reply 0x${got.toRadixString(16)} while waiting for the '
      'device to $what.';

  Future<int> _reply(String what) async {
    if (_aborted) throw StateError('OTA session aborted');
    final waiting = Completer<Uint8List>();
    _waiting = waiting;
    try {
      final data = await waiting.future.timeout(ackTimeout);
      if (data.isEmpty) {
        throw OtaFlashException(
          'Empty reply while waiting for the device to $what.',
        );
      }
      return data[0];
    } on TimeoutException {
      throw OtaFlashException('Timed out waiting for the device to $what.');
    } finally {
      _waiting = null;
    }
  }

  Future<void> _expectReply(int expected, String what) async {
    final got = await _reply(what);
    if (got != expected) {
      throw OtaFlashException(_unexpected(got, what));
    }
  }
}
