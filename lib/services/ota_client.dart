import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ota_protocol.dart';

/// A flash session failure with plain-language copy for the UI.
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
/// The wire sequence: REQUEST with the declared size -> ACK/NAK -> image
/// bytes on the Data characteristic -> DONE -> ACK/NAK, after which the
/// device restarts on its own (~0.5 s later). Two rules come from the
/// reference client (firmware/ota_update.py):
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

  /// Image chunk size: min(MTU - 3, 244); the cap fits platforms that don't
  /// report an MTU (web) but negotiate 247.
  final int chunkSize;

  /// Upper bound on one Control round trip (start covers erasing the slot,
  /// finalize covers digest-checking the image).
  final Duration ackTimeout;

  bool _aborted = false;
  Completer<Uint8List>? _waiting;

  /// Entry point for Control notifications. Settles only the live wait.
  void handleNotification(Uint8List data) {
    final waiting = _waiting;
    if (waiting == null || waiting.isCompleted) return;
    waiting.complete(data);
  }

  /// Fail the live wait, if any.
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
    final request = await _transact(
      encodeOtaRequest(image.length),
      'start the update',
    );
    if (request == otaRequestNak) {
      throw const OtaFlashException('The device declined to start.');
    }
    if (request != otaRequestAck) {
      throw OtaFlashException(_unexpected(request, 'start the update'));
    }

    for (var offset = 0; offset < image.length; offset += chunkSize) {
      if (_aborted) throw StateError('OTA session aborted');
      final end = offset + chunkSize;
      await writeData(
        image.sublist(offset, end > image.length ? image.length : end),
      );
      onProgress?.call(end > image.length ? image.length : end);
    }

    // DONE is sent without response (see class doc).
    final done = await _transact(
      Uint8List.fromList(const [otaDoneOpcode]),
      'finalize the update',
      withoutResponse: true,
    );
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

  /// One handshake round trip. The wait is armed BEFORE the write goes out: the
  /// device notifies inside its write handler, so the reply can race the
  /// write's completion and a later-armed wait would drop it.
  Future<int> _transact(
    Uint8List bytes,
    String what, {
    bool withoutResponse = false,
  }) async {
    if (_aborted) throw StateError('OTA session aborted');
    final waiting = Completer<Uint8List>();
    _waiting = waiting;
    try {
      await writeControl(bytes, withoutResponse: withoutResponse);
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
}
