import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'adc_protocol.dart';
import '../models/force_unit.dart';

/// Storage and derived statistics for the live ADC stream.
///
/// This class owns the ring buffer, minimap buckets, tare state and the
/// analytics the UI reads (current/peak/min force, derivative, AC RMS). It
/// knows nothing about BLE or the wire format: decoded samples arrive through
/// [addSampleFrame] / [addDroppedFrames] (fed by [AdcPacketDecoder]) and each
/// packet is closed out with [commitBatch].
class DataHub extends ChangeNotifier {
  DataHub() {
    assert(
      kDroppedSampleSentinel < -8388608 || kDroppedSampleSentinel > 8388607,
      "Sentinel must be outside 24-bit ADC range",
    );
  }

  /// Number of ADC channels the device streams. This is also the number of
  /// lines stored and displayed: channel index == storage index == display index.
  static const int numAdcChannels = nwNumAdcChan;
  static const int _tareWindow = 1024;
  static const int samplesPerSec = 1000;
  static const int maxDataSz = samplesPerSec * 60 * 10;
  static const int bucketSize = 100;
  static const int numBuckets = maxDataSz ~/ bucketSize;

  final Float64List tare = Float64List(numAdcChannels);
  final Float64List _runningTotal = Float64List(numAdcChannels);
  final Int32List rawMax = Int32List(numAdcChannels);
  final Int32List rawMin = Int32List(numAdcChannels);

  /// Latest raw value per channel (for live stats display).
  final Int32List _currentRaw = Int32List(numAdcChannels);

  final List<Int32List> rawData = List.generate(
    DataHub.numAdcChannels,
    (_) => Int32List(maxDataSz),
    growable: false,
  );

  /// Per-channel, per-bucket aggregates over [bucketSize]-sample windows.
  /// Used by the minimap to render a downsampled overview cheaply.
  final List<Int32List> bucketMins = List.generate(
    DataHub.numAdcChannels,
    (_) => Int32List(numBuckets),
    growable: false,
  );

  final List<Int32List> bucketMaxs = List.generate(
    DataHub.numAdcChannels,
    (_) => Int32List(numBuckets),
    growable: false,
  );

  final List<Int32List> bucketSums = List.generate(
    DataHub.numAdcChannels,
    (_) => Int32List(numBuckets),
    growable: false,
  );
  int _tareCount = 0;
  int totalSamples = 0;
  DeviceCalibration deviceCalibration = DeviceCalibration();

  /// Invoked by [commitBatch] with the exact slice of samples appended by the
  /// decoder for one packet ([startIdx] is the logical index of the first new
  /// sample). This is how [RecordingController] observes new data without the
  /// hub knowing anything about recording.
  void Function(int startIdx, int count)? onSamplesAppended;

  void clear() {
    _tareCount = 0;
    totalSamples = 0;
    for (int i = 0; i < numAdcChannels; ++i) {
      rawMax[i] = 0;
      rawMin[i] = 0;
      tare[i] = 0;
      _runningTotal[i] = 0;
      _currentRaw[i] = 0;
    }
  }

  bool get taring => (_tareCount > 0);

  /// Request a new tare operation (zeros readings using next N samples).
  void requestTare() {
    _tareCount = _tareWindow;
    for (int i = 0; i < numAdcChannels; ++i) {
      tare[i] = 0;
      _runningTotal[i] = 0;
    }
  }

  /// Append one decoded sample (one value per channel). While a tare is in
  /// progress the values are accumulated into the tare average instead of the
  /// ring buffer (and [totalSamples] does not advance).
  void addSampleFrame(Int32List values) {
    assert(values.length >= numAdcChannels);
    for (int i = 0; i < numAdcChannels; ++i) {
      final int val = values[i];
      _currentRaw[i] = val;
      if (taring) {
        _addTare(val, i);
      } else {
        // Always buffer data for live display.
        _addData(val, i);
      }
    }

    if (taring) {
      _tareCount--;
      if (!taring) {
        for (int i = 0; i < _runningTotal.length; ++i) {
          tare[i] = _runningTotal[i] / _tareWindow;
          _runningTotal[i] = 0;
        }
      }
    } else {
      totalSamples++;
    }
  }

  /// Inject [count] dropped-sample sentinels across all channels (the decoder
  /// detected a gap in the packet counter). Capped at [maxDataSz] to avoid a
  /// huge injection loop if the device reboots and the counter jumps. Skipped
  /// while taring, matching [addSampleFrame].
  void addDroppedFrames(int count) {
    int toInject = count;
    if (toInject > maxDataSz) toInject = maxDataSz;
    for (int d = 0; d < toInject; d++) {
      if (!taring) {
        for (int i = 0; i < numAdcChannels; ++i) {
          _addData(kDroppedSampleSentinel, i);
          _currentRaw[i] = kDroppedSampleSentinel;
        }
        totalSamples++;
      }
    }
  }

  /// Close out one decoded packet: fire [onSamplesAppended] for the slice
  /// appended since [startIdx] (the caller snapshots [totalSamples] before
  /// decoding) and notify listeners once per packet.
  void commitBatch(int startIdx) {
    final int count = totalSamples - startIdx;
    if (count > 0) {
      onSamplesAppended?.call(startIdx, count);
    }
    notifyListeners();
  }

  void updateCalibration(DeviceCalibration calibration) {
    deviceCalibration = calibration;
  }

  /// Get current force for a given ADC channel in the specified unit.
  double currentForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels) return 0;
    if (_currentRaw[adcChannel] == kDroppedSampleSentinel) return 0;
    final rawTared = _currentRaw[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get peak force for a given ADC channel in the specified unit.
  double peakForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels) return 0;
    final rawTared = rawMax[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get minimum (most negative) force for a given ADC channel in the specified unit.
  double minForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels) return 0;
    final rawTared = rawMin[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get the instantaneous derivative (first-difference) for a channel in unit/s.
  double currentDerivative(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels || totalSamples < 2) {
      return 0;
    }

    final raw1 = rawData[adcChannel][(totalSamples - 1) % maxDataSz];
    final raw2 = rawData[adcChannel][(totalSamples - 2) % maxDataSz];
    if (raw1 == kDroppedSampleSentinel || raw2 == kDroppedSampleSentinel) {
      return 0;
    }

    final diff = raw1 - raw2;
    // Derivative is raw diff per sample * samplesPerSec to get raw per sec
    return unit.fromRaw(
      diff.toDouble() * samplesPerSec,
      deviceCalibration.slope,
    );
  }

  /// Get the AC RMS for a given ADC channel in the specified unit over the last 1 second window.
  double acRmsForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels || totalSamples == 0) {
      return 0;
    }

    final int count = math.min(samplesPerSec, totalSamples);
    final lineData = rawData[adcChannel];
    final startIdx = totalSamples - count;

    double sum = 0;
    int validCount = 0;
    for (int i = startIdx; i < totalSamples; i++) {
      final val = lineData[i % maxDataSz];
      if (val != kDroppedSampleSentinel) {
        sum += val;
        validCount++;
      }
    }

    if (validCount == 0) return 0;
    final mean = sum / validCount;

    double sumSq = 0;
    for (int i = startIdx; i < totalSamples; i++) {
      final val = lineData[i % maxDataSz];
      if (val != kDroppedSampleSentinel) {
        final diff = val - mean;
        sumSq += diff * diff;
      }
    }
    final rmsRaw = math.sqrt(sumSq / validCount);

    return unit.fromRaw(rmsRaw, deviceCalibration.slope);
  }

  void _addTare(int val, int idx) {
    _runningTotal[idx] += val;
  }

  void _addData(int val, int idx) {
    rawData[idx][totalSamples % maxDataSz] = val;
    if (val != kDroppedSampleSentinel) {
      if (val > rawMax[idx]) {
        rawMax[idx] = val;
      }
      if (val < rawMin[idx]) {
        rawMin[idx] = val;
      }

      final int bIdx = (totalSamples % maxDataSz) ~/ bucketSize;
      final int sIdx = (totalSamples % maxDataSz) % bucketSize;
      if (sIdx == 0) {
        bucketMins[idx][bIdx] = val;
        bucketMaxs[idx][bIdx] = val;
        bucketSums[idx][bIdx] = val;
      } else {
        if (val < bucketMins[idx][bIdx]) bucketMins[idx][bIdx] = val;
        if (val > bucketMaxs[idx][bIdx]) bucketMaxs[idx][bIdx] = val;
        bucketSums[idx][bIdx] += val;
      }
    }
  }
}

class DeviceCalibration {
  DeviceCalibration({
    this.offset = 0,
    this.capacityKg = 200.0,
    this.sensitivityMvV = 2.0,
    this.excitationV = 4.5,
  });

  final int offset;
  final double capacityKg;
  final double sensitivityMvV;
  final double excitationV;

  /// Calculates kgf per raw count dynamically based on the parameters
  double get slope {
    final maxMv = sensitivityMvV * excitationV;
    return (capacityKg * ForceUnit.rawToMvMultiplier) / maxMv;
  }
}
