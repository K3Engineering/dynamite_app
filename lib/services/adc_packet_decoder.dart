import 'package:flutter/foundation.dart';

import 'adc_protocol.dart';
import 'adc_sink.dart';
import '../models/device_profile.dart';
import '../models/hub_event.dart';
import '../utils/log.dart';

/// Decodes the device's ADC-feed notification packets into [AdcSink] updates.
///
/// Owns packet continuity: the 16-bit running sample counter, cross-checked
/// against a monotonic clock of arrival times. The clock de-quantizes the
/// counter's ~65.5 s wrap; beyond slack the clock is the authority. Loss is
/// reported via [AdcSink.addDroppedFrames].
class AdcPacketDecoder {
  AdcPacketDecoder(this.hub, {Duration Function()? now})
    : _now = now ?? (() => _clock.elapsed) {
    // A sink clear means a new device stream: reset so its first packet isn't
    // diffed against the previous stream's counter.
    hub.addEventListener((event) {
      if (event is HubCleared) resetContinuity();
    });
  }

  final AdcSink hub;

  /// Monotonic clock for the cross-check (site-managed time invites NTP-slew
  /// false positives); injectable for tests.
  static final Stopwatch _clock = Stopwatch()..start();
  final Duration Function() _now;

  /// Continuity anchor from the previous packet: the expected value of the
  /// next packet's 16-bit running sample counter (the previous counter plus
  /// its sample count), and [_now] microseconds when the previous packet
  /// arrived. Null when continuity tracking is reset (new device stream,
  /// session boundaries).
  ({int sampleCount, int rxUs})? _prev;

  /// Wrap modulus of the wire sample counter: ~65.5 s at 1 kHz.
  static const int _counterModulus = 0x10000;

  /// Slack between the counter delta and elapsed time, in seconds of samples.
  /// BLE delivery batches under jank, so back-to-back packets routinely
  /// disagree by dozens of intervals; must stay far below half a wrap (~32.7 s).
  static const int _clockToleranceSec = 3;

  /// Reusable frame buffer (one value per channel) passed to
  /// [AdcSink.addSampleFrame], which copies out of it synchronously.
  final Int32List _frame = Int32List(kAdcChannelCount);

  /// Forget the last counter so the next packet isn't diffed against a stale
  /// value. Self-invoked on a new stream; also requested at session boundaries.
  void resetContinuity() {
    _prev = null;
  }

  /// Parse one BLE ADC-feed notification packet into the sink.
  ///
  /// Data is always buffered for live display; recording observes the sink
  /// via [HubBatchAppended] (emitted from [AdcSink.commitBatch]).
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
    final prev = _prev;
    if (prev != null) {
      final int diff = (count - prev.sampleCount) & 0xFFFF;
      // Samples the clock says elapsed since the previous packet (measured
      // between deliveries, so loss can be anywhere along the path).
      final int elapsedSamples =
          ((rxUs - prev.rxUs) * rate + 500000) ~/ 1000000;
      // De-quantize the counter's wrap: a gap of g samples shows as
      // g % _counterModulus, and the clock only needs to resolve half a
      // wrap (~32 s at 1 kHz) against sub-second delivery jitter to pick g
      // exactly.
      int wraps = ((elapsedSamples - diff) / _counterModulus).round();
      if (wraps < 0) wraps = 0;
      final int gap = diff + wraps * _counterModulus;
      // Within slack, report the counter's wrap-resolved gap; beyond it the
      // clock is the authority.
      final int loss = (elapsedSamples - gap).abs() <= _clockToleranceSec * rate
          ? gap
          : elapsedSamples;
      if (loss > 0) {
        logTrace(() => '# lost $loss samples');
        // Report the dropped range to the sink (capped inside the sink).
        hub.addDroppedFrames(loss);
      }
    }
    _prev = (sampleCount: (count + n) & 0xFFFF, rxUs: rxUs);

    // Anchor the counter to the sink timeline (after gap injection). The
    // writer derives ssn_origin from this pairing.
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
