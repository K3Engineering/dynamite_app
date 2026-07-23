import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'adc_protocol.dart';
import '../models/bucket_series.dart';
import '../models/calibration.dart';
import '../models/force_unit.dart';
import '../models/gap_list.dart';
import '../models/graph_data_source.dart';

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
///
/// Implements [GraphDataSource] directly (no adapter): the graph components
/// read the ring buffer, buckets and gaps through the interface, and repaint
/// off this notifier. The [totalSamples] and [gaps] fields already satisfy
/// their interface counterparts; the rest are thin getters over existing
/// state.
class DataHub extends ChangeNotifier implements GraphDataSource {
  /// Number of ADC channels the device streams. This is also the number of
  /// lines stored and displayed: channel index == storage index == display index.
  static const int numAdcChannels = nwNumAdcChan;
  static const int _tareWindow = 1024;
  static const int samplesPerSec = 1000;
  static const int maxDataSz = samplesPerSec * 60 * 10;
  static const int bucketSize = kBucketSize;
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

  /// The shared per-sample ingester feeding [valueBuckets]/[diffBuckets]
  /// (see [ChannelIngest]).
  late final List<ChannelIngest> _ingest = List.generate(
    DataHub.numAdcChannels,
    (i) => ChannelIngest(
      valueBuckets: valueBuckets[i],
      diffBuckets: diffBuckets[i],
      gaps: gaps,
    ),
    growable: false,
  );
  int _tareCount = 0;
  @override
  int totalSamples = 0;
  DeviceCalibration deviceCalibration = DeviceCalibration();

  /// Factory board calibration read from the device at connect time (parsed
  /// by [AdcPacketDecoder.onCalibrationPacket]). Nominal per-channel fallback
  /// until/unless a calibrated device supplies real data.
  BoardCalibration boardCalibration = BoardCalibration.nominal();

  /// Whether a malformed/undecodable ADC packet (e.g. a truncated
  /// notification) was seen on this stream. Latched by [reportProtocolError]
  /// instead of silently dropping; the live UI surfaces the latch. Reset by
  /// [clear].
  bool protocolErrorSeen = false;

  /// Wall-clock time of the last completed packet batch ([commitBatch]), or
  /// null before the first packet of the stream. The live UI derives a
  /// data-stall indication from this: while the link reports streaming, a
  /// timestamp older than a couple of seconds means the device has gone
  /// silent (firmware hang / marginal link). Reset by [clear].
  DateTime? lastDataAt;

  /// Monotonic counter bumped by [clear]. Lets observers distinguish "same
  /// stream, more data" from "a new stream reset the hub" explicitly, instead
  /// of inferring the reset from [totalSamples] decreasing.
  int _generation = 0;
  int get generation => _generation;

  /// Sample ranges lost to dropped BLE packets (absolute indices). The ring
  /// buffer holds the held previous value across these ranges.
  @override
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

  /// Observers notified once per [clear] — a new device stream just reset the
  /// hub, so views must drop stale pan/zoom windows instead of clamping them
  /// against an empty buffer. Lets observers react to resets explicitly
  /// instead of mirroring [generation] and comparing on every notify.
  final ObserverList<void Function()> _clearedListeners =
      ObserverList<void Function()>();

  void addClearedListener(void Function() listener) =>
      _clearedListeners.add(listener);

  void removeClearedListener(void Function() listener) =>
      _clearedListeners.remove(listener);

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
    lastDataAt = null;
    gaps.clear();
    for (int i = 0; i < numAdcChannels; ++i) {
      rawMax[i] = _noMaxYet;
      rawMin[i] = _noMinYet;
      tare[i] = 0;
      _runningTotal[i] = 0;
      _currentRaw[i] = 0;
      _ingest[i].reset();
    }
    for (final listener in _clearedListeners) {
      listener();
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
  ///
  /// TODO(perf): a reboot jump can inject up to ~262k held samples (65,535 x
  /// 4 channels) synchronously inside one BLE callback, stalling the UI
  /// isolate for a beat. If that becomes visible, chunk the injection across
  /// frames (or fast-forward the ring/bucket state without per-sample work).
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
    lastDataAt = DateTime.now();
    gaps.pruneBefore(totalSamples - maxDataSz); // ring-wrap hygiene
    notifyListeners();
  }

  void updateCalibration(DeviceCalibration calibration) {
    deviceCalibration = calibration;
  }

  void updateBoardCalibration(BoardCalibration calibration) {
    boardCalibration = calibration;
  }

  // -- GraphDataSource --------------------------------------------------------

  @override
  int get bufferCapacity => maxDataSz;

  @override
  int get oldestSample =>
      totalSamples > maxDataSz ? totalSamples - maxDataSz : 0;

  @override
  int get sampleRate => samplesPerSec;

  @override
  double get calibrationSlope => deviceCalibration.slope;

  @override
  Listenable get repaint => this;

  /// Stream identity for the graph segment caches: [generation] is bumped by
  /// [clear], i.e. exactly when a new device stream takes over the hub.
  @override
  int get dataGeneration => _generation;

  @override
  ChannelSeries channel(int channelIndex) => (
    data: rawData[channelIndex],
    min: rawMin[channelIndex].toDouble(),
    max: rawMax[channelIndex].toDouble(),
    tare: tare[channelIndex],
    buckets: valueBuckets[channelIndex].series,
  );

  @override
  BucketSeries? diffBucketsFor(int channelIndex) =>
      diffBuckets[channelIndex].series;

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
    // The previous-value read is safe for totalSamples == 0 (Dart % is
    // non-negative) and ignored by the ingest diff rule there.
    final int prev = rawData[idx][(totalSamples - 1) % maxDataSz];
    rawData[idx][totalSamples % maxDataSz] = val;
    if (val > rawMax[idx]) {
      rawMax[idx] = val;
    }
    if (val < rawMin[idx]) {
      rawMin[idx] = val;
    }
    _ingest[idx].add(totalSamples, val, prev);
  }
}

/// Calibration parameters of a load cell channel and the resulting
/// raw-count -> kgf slope.
///
/// Signal chain (per-channel device parameters — becoming configurable via
/// the device's calibration characteristic):
///   [excitationV] excitation
///   -> load cell ([sensitivityMvV] mV/V at [capacityKg] full scale, i.e.
///      sensitivity x excitation mV output at full-scale load)
///   -> 101x front-end gain
///   -> 1.2V FSR 24-bit bipolar ADC (constants in force_unit.dart)
///
/// Today every field is a compile-time default; the decoder reads the
/// calibration characteristic but parsing is a TODO.
class DeviceCalibration {
  DeviceCalibration({
    this.capacityKg = 200.0,
    this.sensitivityMvV = 2.0,
    this.excitationV = 4.53,
  });

  final double capacityKg;
  final double sensitivityMvV;
  final double excitationV;

  /// kgf per raw count: the full-scale output ([sensitivityMvV] x
  /// [excitationV] mV at [capacityKg]) mapped through the front-end's
  /// mV-per-count.
  double get slope {
    final maxMv = sensitivityMvV * excitationV;
    return capacityKg * rawToMvMultiplier / maxMv;
  }
}
