import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'adc_protocol.dart';
import 'adc_sink.dart';
import '../models/device_flash.dart';
import '../models/device_profile.dart';
import '../utils/log.dart';

/// Protocol layer: decodes the device's ADC-feed notification packets and the
/// calibration characteristic into [AdcSink] updates.
///
/// Owns the packet-continuity counter used to detect dropped packets (reported
/// to the sink via [AdcSink.addDroppedFrames]).
class AdcPacketDecoder {
  AdcPacketDecoder(this.hub) {
    // A sink clear means a NEW device stream just took over; its first packet
    // must not be diffed against the previous stream's counter. The sink's
    // cleared event IS the stream-boundary signal, so the decoder resets
    // itself rather than the link-change orchestrator doing it.
    hub.addClearedListener(resetContinuity);
  }

  final AdcSink hub;

  /// Expected value of the next packet's 16-bit running sample counter, or -1
  /// when continuity tracking is reset (new device stream, session
  /// boundaries).
  int _prevSampleCount = -1;

  /// Reusable frame buffer (one value per channel) passed to
  /// [AdcSink.addSampleFrame], which copies out of it synchronously.
  final Int32List _frame = Int32List(kAdcChannelCount);

  /// Forget the last seen packet counter so the next packet is not diffed
  /// against a stale value (which would report spurious dropped samples).
  /// Self-invoked on a new device stream (via the hub's cleared listeners,
  /// see the constructor); `RecordingController` requests it at session
  /// boundaries through the session-boundary callback main wires here.
  void resetContinuity() {
    _prevSampleCount = -1;
  }

  /// Invoked with every successfully parsed flash document (board + load
  /// cell slots).
  void Function(DeviceFlash flash)? onDeviceFlash;

  /// Parse one flash document read: the `key=value` document the link layer
  /// reassembled from the device KVS ([DeviceFlash.parse], tolerant of
  /// missing keys), plus the ADC's per-channel PGA gains read back alongside
  /// ([adcGains], null when that read failed — the board constants then
  /// resolve to the unreadable verdict). The board calibration feeds the
  /// sink; the full document (slots included) goes to [onDeviceFlash].
  /// Malformed reads degrade to per-channel nominal values and empty slots.
  void onCalibrationPacket(Uint8List data, List<double>? adcGains) {
    final flash = DeviceFlash.parse(
      utf8.decode(data, allowMalformed: true),
      pgaGains: adcGains,
    );
    hub.updateBoardCalibration(flash.board);
    onDeviceFlash?.call(flash);
  }

  /// Parse one BLE ADC-feed notification packet into the sink.
  ///
  /// Data is always buffered for live display; recording observes the sink via
  /// `DataHub.addSamplesAppendedListener` (notified from
  /// [AdcSink.commitBatch]).
  void onDataPacket(Uint8List data) {
    final n = adcSamplesInPacket(data.length);
    if (n == null) {
      hub.noteMalformedPacket(data.length);
      debugPrint('Dropping bad ADC packet: ${data.length} B');
      return;
    }

    final int startIdx = hub.totalSamples;

    final int count = data[0] + (data[1] << 8);
    if (_prevSampleCount != -1) {
      final int diff = (count - _prevSampleCount) & 0xFFFF;
      if (diff != 0) {
        logTrace(() => '# lost $diff samples');
        // Report the dropped range to the sink (capped inside the sink to
        // avoid OOM if the device reboots and the counter jumps).
        hub.addDroppedFrames(diff);
      }
    }
    _prevSampleCount = (count + n) & 0xFFFF;

    // Anchor the packet's counter to the sink timeline (after gap injection,
    // so totalSamples is this packet's first-sample index). The recording
    // writer derives the session's ssn_origin from this pairing.
    hub.notePacketCounter(count);

    for (
      int packetStart = wireAdcHeaderSize;
      packetStart < wireAdcHeaderSize + n * wireAdcSampleLength;
      packetStart += wireAdcSampleLength
    ) {
      for (int i = 0; i < kAdcChannelCount; ++i) {
        final int baseIndex = packetStart + i * 3;
        _frame[i] =
            ((data[baseIndex] << 0) |
                    (data[baseIndex + 1] << 8) |
                    data[baseIndex + 2] << 16)
                .toSigned(24);
      }
      hub.addSampleFrame(_frame);
    }

    hub.commitBatch(startIdx);
  }
}
