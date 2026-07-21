import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'adc_protocol.dart';
import '../models/bucket_series.dart';
import '../models/force_unit.dart';
import '../models/gap_list.dart';

/// Invoked by [DataHub.commitBatch] with the exact slice of samples appended
/// by the decoder for one packet ([startIdx] is the logical index of the
/// first new sample).
typedef SamplesAppendedListener = void Function(int startIdx, int count);

/// Storage and derived statistics for the live ADC stream.
///
/// This class owns the ring buffer, minimap buckets, tare state and the
/// analytics the UI reads (current/peak/min force and the derivative). It
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

  /// "No sample seen yet" sentinels for [rawMax]/[rawMin]: int32 min/max, so
  /// the first real sample always replaces them. Initializing to 0 instead
  /// would bias the extremes toward zero (a never-positive channel would
  /// report a peak of `0 - tare`). ADC values are 24-bit, well inside int32.
  static const int _noMaxYet = -0x80000000;
  static const int _noMinYet = 0x7FFFFFFF;

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

  /// Whether a malformed/undecodable ADC packet (e.g. a truncated
  /// notification) was seen on this stream. Latched by [reportProtocolError]
  /// instead of silently dropping; the live UI surfaces the latch. Reset by
  /// [clear].
  bool protocolErrorSeen = false;

  /// Monotonic counter bumped by [clear]. Lets observers distinguish "same
  /// stream, more data" from "a new stream reset the hub" explicitly, instead
  /// of inferring the reset from [totalSamples] decreasing.
  int _generation = 0;
  int get generation => _generation;

  /// Sample ranges lost to dropped BLE packets (absolute indices). The ring
  /// buffer holds the held previous value across these ranges.
  final GapList gaps = GapList();

  /// Observers notified by [commitBatch] with the exact slice of samples
  /// appended by the decoder for one packet. This is how
  /// [RecordingController] observes new data without the hub knowing anything
  /// about recording. [ObserverList] (the same mechanism [ChangeNotifier]
  /// uses) keeps removal-during-dispatch safe.
  final ObserverList<SamplesAppendedListener> _samplesAppendedListeners =
      ObserverList<SamplesAppendedListener>();

  void addSamplesAppendedListener(SamplesAppendedListener listener) =>
      _samplesAppendedListeners.add(listener);

  void removeSamplesAppendedListener(SamplesAppendedListener listener) =>
      _samplesAppendedListeners.remove(listener);

  DataHub() {
    clear();
  }

  /// Reset every per-stream accumulation: ring position, peaks, tare, gaps
  /// and buckets. Invoked from the constructor and by [RecordingController]
  /// each time a new device stream starts, so two connections (or two
  /// devices) never splice into one trace and "Peak" never survives a
  /// disconnect.
  ///
  /// Deliberately does NOT touch [deviceCalibration]: a connecting device's
  /// calibration is read during post-connect setup, BEFORE the streaming
  /// transition that triggers this reset.
  void clear() {
    _tareCount = 0;
    totalSamples = 0;
    _generation++;
    protocolErrorSeen = false;
    gaps.clear();
    for (int i = 0; i < numAdcChannels; ++i) {
      rawMax[i] = _noMaxYet;
      rawMin[i] = _noMinYet;
      tare[i] = 0;
      _runningTotal[i] = 0;
      _currentRaw[i] = 0;
      valueBuckets[i].reset();
      diffBuckets[i].reset();
    }
    notifyListeners();
  }

  /// Latch [protocolErrorSeen] and notify observers — but only on the first
  /// malformed packet of a stream. The malformed-packet path never reaches
  /// [commitBatch], so without this notify a stream where EVERY packet is
  /// undecodable (firmware/protocol mismatch) would show no warning at all;
  /// latching keeps a flood of bad packets from becoming a notify storm.
  void reportProtocolError() {
    if (protocolErrorSeen) return;
    protocolErrorSeen = true;
    notifyListeners();
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

  /// Append one decoded sample (one value per channel). Samples are always
  /// buffered and [totalSamples] always advances — including while a tare is
  /// in progress, so taring never warps the stream's timeline or punches an
  /// unmarked hole in an ongoing recording. A tare only re-zeros the display
  /// offset: while taring, each real frame is ADDITIONALLY accumulated into
  /// the tare average.
  void addSampleFrame(Int32List values) {
    assert(values.length >= numAdcChannels);
    for (int i = 0; i < numAdcChannels; ++i) {
      final int val = values[i];
      _currentRaw[i] = val;
      // Always buffer data for live display.
      _addData(val, i);
      if (taring) {
        _addTare(val, i);
      }
    }
    totalSamples++;

    if (taring) {
      _tareCount--;
      if (!taring) {
        for (int i = 0; i < _runningTotal.length; ++i) {
          tare[i] = _runningTotal[i] / _tareWindow;
          _runningTotal[i] = 0;
        }
      }
    }
  }

  /// Record [count] dropped samples (the decoder detected a gap in the packet
  /// counter): append the range to [gaps] and hold each channel's last value
  /// ([_currentRaw]) in the ring buffer so the stored data stays magic-free.
  /// Capped at [maxDataSz] to avoid a huge injection loop if the device
  /// reboots and the counter jumps. Held samples are real ring-buffer time
  /// (they advance [totalSamples]) but are NOT real readings, so they are
  /// never accumulated into an in-progress tare average.
  void addDroppedFrames(int count) {
    final int toInject = math.min(count, maxDataSz);
    gaps.append(totalSamples, totalSamples + toInject);
    for (int d = 0; d < toInject; d++) {
      for (int i = 0; i < numAdcChannels; ++i) {
        _addData(_currentRaw[i], i);
      }
      totalSamples++;
    }
  }

  /// Close out one decoded packet: notify [SamplesAppendedListener]s of the
  /// slice appended since [startIdx] (the caller snapshots [totalSamples]
  /// before decoding) and notify listeners once per packet.
  void commitBatch(int startIdx) {
    final int count = totalSamples - startIdx;
    if (count > 0) {
      for (final listener in _samplesAppendedListeners) {
        listener(startIdx, count);
      }
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
    assert(adcChannel >= 0 && adcChannel < numAdcChannels);
    final rawTared = _currentRaw[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get peak force for a given ADC channel in the specified unit. Returns 0
  /// before the first sample arrives ([rawMax] still holds its sentinel).
  double peakForce(int adcChannel, ForceUnit unit) {
    assert(adcChannel >= 0 && adcChannel < numAdcChannels);
    if (totalSamples == 0) return 0;
    final rawTared = rawMax[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get minimum (most negative) force for a given ADC channel in the
  /// specified unit. Returns 0 before the first sample arrives.
  double minForce(int adcChannel, ForceUnit unit) {
    assert(adcChannel >= 0 && adcChannel < numAdcChannels);
    if (totalSamples == 0) return 0;
    final rawTared = rawMin[adcChannel] - tare[adcChannel];
    return unit.fromRaw(rawTared.toDouble(), deviceCalibration.slope);
  }

  /// Get the instantaneous derivative (first-difference) for a channel in unit/s.
  double currentDerivative(int adcChannel, ForceUnit unit) {
    assert(adcChannel >= 0 && adcChannel < numAdcChannels);
    if (totalSamples < 2) return 0;

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
    this.excitationV = 4.53,
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
