import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'adc_protocol.dart';
import '../models/bucket_series.dart';
import '../models/force_unit.dart';
import '../models/gap_list.dart';

/// Storage and derived statistics for the live ADC stream.
///
/// This class owns the ring buffer, minimap buckets, tare state and the
/// analytics the UI reads (current/peak/min force, derivative, AC RMS). It
/// knows nothing about BLE or the wire format: decoded samples arrive through
/// [addSampleFrame] / [addDroppedFrames] (fed by [AdcPacketDecoder]) and each
/// packet is closed out with [commitBatch].
///
/// Dropped samples are tracked out-of-band in [gaps]; the ring buffer holds
/// the previous sample's value across a gap, so every stored value is a real
/// ADC reading and downstream consumers need no magic-value checks.
class DataHub extends ChangeNotifier {

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

  /// Per-channel bucket aggregates over [bucketSize]-sample windows of the
  /// raw values. Used by the graph envelope renderers to downsample cheaply.
  /// Gap samples hold the previous real value, so buckets are always fully
  /// populated and need no missing-data handling.
  final List<BucketAccumulator> valueBuckets = List.generate(
    DataHub.numAdcChannels,
    (_) => BucketAccumulator(bucketSize: bucketSize, numBuckets: numBuckets),
    growable: false,
  );

  /// Per-channel bucket aggregates of the first-difference series
  /// (`diff[j] = raw[j] - raw[j-1]`), same bucket grid as [valueBuckets].
  /// Used by the derivative graph's bucket fast path; the gap/first-sample
  /// diff rule lives in [ingestDiff].
  final List<BucketAccumulator> diffBuckets = List.generate(
    DataHub.numAdcChannels,
    (_) => BucketAccumulator(bucketSize: bucketSize, numBuckets: numBuckets),
    growable: false,
  );
  int _tareCount = 0;
  int totalSamples = 0;
  DeviceCalibration deviceCalibration = DeviceCalibration();

  /// Sample ranges lost to dropped BLE packets (absolute indices). The ring
  /// buffer holds the held previous value across these ranges.
  final GapList gaps = GapList();

  /// Invoked by [commitBatch] with the exact slice of samples appended by the
  /// decoder for one packet ([startIdx] is the logical index of the first new
  /// sample). This is how [RecordingController] observes new data without the
  /// hub knowing anything about recording.
  void Function(int startIdx, int count)? onSamplesAppended;

  void clear() {
    _tareCount = 0;
    totalSamples = 0;
    gaps.clear();
    for (int i = 0; i < numAdcChannels; ++i) {
      rawMax[i] = 0;
      rawMin[i] = 0;
      tare[i] = 0;
      _runningTotal[i] = 0;
      _currentRaw[i] = 0;
      valueBuckets[i].reset();
      diffBuckets[i].reset();
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

  /// Record [count] dropped samples (the decoder detected a gap in the packet
  /// counter): append the range to [gaps] and hold each channel's last value
  /// ([_currentRaw]) in the ring buffer so the stored data stays magic-free.
  /// Capped at [maxDataSz] to avoid a huge injection loop if the device
  /// reboots and the counter jumps. Skipped while taring, matching
  /// [addSampleFrame] (totalSamples does not advance during a tare).
  void addDroppedFrames(int count) {
    if (taring) return;
    final int toInject = math.min(count, maxDataSz);
    gaps.append(totalSamples, totalSamples + toInject);
    for (int d = 0; d < toInject; d++) {
      for (int i = 0; i < numAdcChannels; ++i) {
        _addData(_currentRaw[i], i);
      }
      totalSamples++;
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
    gaps.pruneBefore(totalSamples - maxDataSz); // ring-wrap hygiene
    notifyListeners();
  }

  void updateCalibration(DeviceCalibration calibration) {
    deviceCalibration = calibration;
  }

  /// Whether the newest sample is a dropped one — i.e. the live readings the
  /// stats display are held values, not fresh data.
  bool get liveEdgeIsGap => gaps.contains(totalSamples - 1);

  /// Get current force for a given ADC channel in the specified unit. During
  /// a gap this returns the held (last real) value; check [liveEdgeIsGap] to
  /// mark it stale in the UI.
  double currentForce(int adcChannel, ForceUnit unit) {
    if (adcChannel < 0 || adcChannel >= numAdcChannels) return 0;
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

    // A held value on either side would fabricate a flat or spiking
    // derivative; report 0 across gap edges instead.
    if (gaps.contains(totalSamples - 1) || gaps.contains(totalSamples - 2)) {
      return 0;
    }

    final raw1 = rawData[adcChannel][(totalSamples - 1) % maxDataSz];
    final raw2 = rawData[adcChannel][(totalSamples - 2) % maxDataSz];

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
      if (gaps.contains(i)) continue; // held value, not a real reading
      sum += lineData[i % maxDataSz];
      validCount++;
    }

    if (validCount == 0) return 0;
    final mean = sum / validCount;

    double sumSq = 0;
    for (int i = startIdx; i < totalSamples; i++) {
      if (gaps.contains(i)) continue;
      final diff = lineData[i % maxDataSz] - mean;
      sumSq += diff * diff;
    }
    final rmsRaw = math.sqrt(sumSq / validCount);

    return unit.fromRaw(rmsRaw, deviceCalibration.slope);
  }

  void _addTare(int val, int idx) {
    _runningTotal[idx] += val;
  }

  void _addData(int val, int idx) {
    // First difference vs the previous sample, ingested alongside the value;
    // the 0-for-first-sample/gap/gap-exit rule lives in [ingestDiff]. The
    // ring read is safe for totalSamples == 0 (Dart % is non-negative) and
    // ignored by rule there.
    final int diff = ingestDiff(
      sampleIndex: totalSamples,
      value: val,
      prevValue: rawData[idx][(totalSamples - 1) % maxDataSz],
      gaps: gaps,
    );

    rawData[idx][totalSamples % maxDataSz] = val;
    if (val > rawMax[idx]) {
      rawMax[idx] = val;
    }
    if (val < rawMin[idx]) {
      rawMin[idx] = val;
    }

    valueBuckets[idx].add(totalSamples, val);
    diffBuckets[idx].add(totalSamples, diff);
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
