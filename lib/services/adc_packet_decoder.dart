import 'package:flutter/foundation.dart';

import 'adc_protocol.dart';
import 'data_hub.dart';

/// Protocol layer: decodes the device's ADC-feed notification packets and the
/// calibration characteristic into [DataHub] updates.
///
/// Owns the packet-continuity counter used to detect dropped packets (reported
/// to the hub via [DataHub.addDroppedFrames]). Knows nothing about
/// BLE plumbing or recording: [BleLinkManager] hands it raw bytes via
/// [onDataPacket] / [onCalibrationPacket], and it feeds decoded samples into
/// the hub's public API.
class AdcPacketDecoder {
  AdcPacketDecoder(this.hub);

  final DataHub hub;

  /// Expected value of the next packet's 16-bit running sample counter, or -1
  /// when continuity tracking is reset (link start, session boundaries).
  int _prevSampleCount = -1;

  /// Reusable frame buffer (one value per channel) passed to
  /// [DataHub.addSampleFrame], which copies out of it synchronously.
  final Int32List _frame = Int32List(nwNumAdcChan);

  /// Forget the last seen packet counter so the next packet is not diffed
  /// against a stale value (which would report spurious dropped samples).
  /// Called when a new device stream starts (see [RecordingController]) and
  /// at recording start/stop.
  void resetContinuity() {
    _prevSampleCount = -1;
  }

  /// Parse one calibration characteristic read.
  void onCalibrationPacket(Uint8List data) {
    // TODO: implement calibration parsing
    final calibration = DeviceCalibration();
    debugPrint(
      'Calibration ${calibration.slope}, offset ${calibration.offset}',
    );
    hub.updateCalibration(calibration);
  }

  /// Parse one BLE ADC-feed notification packet into the hub.
  ///
  /// Data is always buffered for live display; recording observes the hub via
  /// [DataHub.addSamplesAppendedListener] (notified from
  /// [DataHub.commitBatch]).
  void onDataPacket(Uint8List data) {
    // A decodable packet holds the 2-byte counter plus at least
    // nwAdcNumSamples full frames (extra trailing bytes are ignored, matching
    // the fixed-size loop below). Anything shorter — e.g. a truncated
    // notification from a firmware bug — can't be parsed (indexing past the
    // end would throw in release builds). Drop it, but NOT silently: the
    // hub's [DataHub.reportProtocolError] latch surfaces it in the live UI.
    const int minLength = nwHeaderSize + nwAdcNumSamples * nwAdcSampleLength;
    if (data.length < minLength) {
      hub.reportProtocolError();
      debugPrint(
        'Dropping short ADC packet: ${data.length} B (need $minLength B)',
      );
      return;
    }

    final int startIdx = hub.totalSamples;

    final int count = data[0] + (data[1] << 8);
    if (_prevSampleCount != -1) {
      final int diff = (count - _prevSampleCount) & 0xFFFF;
      if (diff != 0) {
        debugPrint('# lost $diff samples');
        // Report the dropped range to the hub (capped inside the hub to avoid
        // OOM if the device reboots and the counter jumps).
        hub.addDroppedFrames(diff);
        // TODO: signal lost packets to the UI?
      }
    }
    _prevSampleCount = (count + nwAdcNumSamples) & 0xFFFF;

    for (
      int packetStart = nwHeaderSize;
      packetStart < nwHeaderSize + nwAdcNumSamples * nwAdcSampleLength;
      packetStart += nwAdcSampleLength
    ) {
      for (int i = 0; i < nwNumAdcChan; ++i) {
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
