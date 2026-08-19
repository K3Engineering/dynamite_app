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
/// Owns packet continuity: the 16-bit running sample counter, cross-checked
/// against a monotonic clock of packet arrival times. The device samples
/// continuously, so elapsed time and the counter must agree within slack —
/// the clock de-quantizes the counter's ~65.5 s wrap (a loss of an exact
/// wrap multiple would read as continuity on the counter alone). When counter
/// and clock disagree beyond the slack (a firmware counter bug — a reboot
/// drops the link instead), the clock is the authority. Detected loss is
/// reported to the sink via [AdcSink.addDroppedFrames].
class AdcPacketDecoder {
  AdcPacketDecoder(this.hub, {Duration Function()? now})
    : _now = now ?? (() => _clock.elapsed) {
    // A sink clear means a NEW device stream just took over; its first packet
    // must not be diffed against the previous stream's counter. The sink's
    // cleared event IS the stream-boundary signal, so the decoder resets
    // itself rather than the link-change orchestrator doing it.
    hub.addClearedListener(resetContinuity);
  }

  final AdcSink hub;

  /// Monotonic clock for the counter cross-check (site-managed time would
  /// invite NTP-slew false positives). Injectable via the constructor for
  /// tests.
  static final Stopwatch _clock = Stopwatch()..start();
  final Duration Function() _now;

  /// Expected value of the next packet's 16-bit running sample counter, or -1
  /// when continuity tracking is reset (new device stream, session
  /// boundaries).
  int _prevSampleCount = -1;

  /// [_now] microseconds at the previous packet; null iff [_prevSampleCount]
  /// is -1 (the pair is stamped together so they can never half-agree).
  int? _prevRxUs;

  /// Wrap modulus of the wire sample counter: ~65.5 s at 1 kHz.
  static const int _counterModulus = 0x10000;

  /// Slack allowed between the counter delta and elapsed time, in SECONDS of
  /// samples. Fat on purpose: BLE delivery batches under isolate jank, so
  /// back-to-back delivered packets routinely disagree by dozens of packet
  /// intervals. This only needs to stay far below half a wrap period
  /// (~32.7 s at 1 kHz) for the wrap de-quantization in [onDataPacket] to be
  /// exact arithmetic.
  static const int _clockToleranceSec = 3;

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
    _prevRxUs = null;
  }

  /// Invoked with every successfully parsed flash document (board + load
  /// cell slots).
  void Function(DeviceFlash flash)? onDeviceFlash;

  /// Parse one flash document read: the `key=value` document the link layer
  /// reassembled from the device KVS ([DeviceFlash.parse], tolerant of
  /// missing keys), plus the ADC's per-channel PGA gains from the config
  /// readback ([adcGains] — non-null: an unreadable config fails the
  /// connection upstream, so this layer never resolves constants without
  /// them). The board calibration feeds the sink; the full document (slots
  /// included) goes to [onDeviceFlash]. Malformed reads degrade to
  /// per-channel nominal values and empty slots.
  void onCalibrationPacket(Uint8List data, List<double> adcGains) {
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

    final int rxUs = _now().inMicroseconds;
    final int rate = hub.sampleRateHz;
    final int count = data[0] + (data[1] << 8);
    if (_prevSampleCount != -1) {
      final int diff = (count - _prevSampleCount) & 0xFFFF;
      // Samples the clock says elapsed since the previous packet. Measured
      // between delivered packets, so the loss can live anywhere along the
      // path (radio, OS buffer, firmware queue) as long as the device's
      // counter honestly counted the produced samples.
      final int elapsedSamples =
          ((rxUs - _prevRxUs!) * rate + 500000) ~/ 1000000;
      // De-quantize the counter's wrap: a gap of g samples shows as
      // g % _counterModulus, and the clock only needs to resolve half a
      // wrap (~32 s at 1 kHz) against sub-second delivery jitter to pick g
      // exactly.
      int wraps = ((elapsedSamples - diff) / _counterModulus).round();
      if (wraps < 0) wraps = 0;
      final int gap = diff + wraps * _counterModulus;
      // Within slack the counter is consistent with the clock — report its
      // (wrap-resolved) gap. Beyond it the counter is lying (firmware bug);
      // the monotonic clock is the authority.
      final int loss = (elapsedSamples - gap).abs() <=
              _clockToleranceSec * rate
          ? gap
          : elapsedSamples;
      if (loss > 0) {
        logTrace(() => '# lost $loss samples');
        // Report the dropped range to the sink (capped inside the sink).
        hub.addDroppedFrames(loss);
      }
    }
    _prevSampleCount = (count + n) & 0xFFFF;
    _prevRxUs = rxUs;

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
