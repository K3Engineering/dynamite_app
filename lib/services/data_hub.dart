import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/device_profile.dart';
import '../models/bucket_series.dart';
import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';
import '../models/load_cell.dart';
import '../models/display_unit.dart';
import '../models/gap_list.dart';
import '../models/graph_data_source.dart';
import '../models/sample_slice.dart';
import 'adc_sink.dart';

/// Invoked by [DataHub.commitBatch] with the exact slice of samples appended
/// by the decoder for one packet ([startIdx] is the logical index of the
/// first new sample).
typedef SamplesAppendedListener = void Function(int startIdx, int count);

/// Storage and derived statistics for the live ADC stream.
///
/// Dropped samples are tracked out-of-band in [gaps]; the ring buffer holds
/// the previous sample's value across a gap, so every stored value is a real
/// ADC reading and downstream consumers need no magic-value checks.
///
/// Channel count is [kAdcChannelCount]; channel index == storage index ==
/// display index.
class DataHub extends ChangeNotifier implements GraphDataSource, AdcSink {
  static const int _tareWindow = 1024;

  /// Ring capacity in samples — ~10 min at the 1 kHz the device boots at.
  /// A capacity decision, NOT derived from the device rate ([sampleRateHz]):
  /// a faster stream simply covers less time in the same memory.
  static const int maxDataSz = 600 * 1000;
  static const int bucketSize = kBucketSize;
  static const int numBuckets = maxDataSz ~/ bucketSize;

  /// The active stream's sample rate (Hz), parsed from the device's config
  /// readback and pushed by the link layer ([setSampleRate]) before
  /// streaming starts. 1000 before any link: a display default so the
  /// pre-connection UI (graph span readouts) has a defined value — the
  /// number is only trusted downstream (recording metadata, the decoder's
  /// continuity cross-check) once a link's readback has landed, and the
  /// config read is mandatory, so a link without it never reaches streaming.
  @override
  int get sampleRateHz => _sampleRateHz;
  int _sampleRateHz = 1000;

  /// Push the sample rate parsed from the device config readback (once per
  /// link, before the feed subscription).
  void setSampleRate(int hz) => _sampleRateHz = hz;

  /// "No sample seen yet" sentinels for [rawMax]/[rawMin]: int32 min/max, so
  /// the first real sample always replaces them. Initializing to 0 instead
  /// would bias the extremes toward zero (a never-positive channel would
  /// report a peak of `0 - tare`). ADC values are 24-bit, well inside int32.
  static const int _noMaxYet = -0x80000000;
  static const int _noMinYet = 0x7FFFFFFF;

  final Float64List tare = Float64List(kAdcChannelCount);
  final Float64List _runningTotal = Float64List(kAdcChannelCount);
  final Int32List rawMax = Int32List(kAdcChannelCount);
  final Int32List rawMin = Int32List(kAdcChannelCount);

  /// Latest raw value per channel (for live stats display).
  final Int32List _currentRaw = Int32List(kAdcChannelCount);

  final List<Int32List> rawData = List.generate(
    kAdcChannelCount,
    (_) => Int32List(maxDataSz),
    growable: false,
  );

  /// Per-channel bucket aggregates over [bucketSize]-sample windows of the
  /// raw values. Used by the graph envelope renderers to downsample cheaply.
  /// Gap samples hold the previous real value, so buckets are always fully
  /// populated and need no missing-data handling.
  final List<BucketAccumulator> valueBuckets = List.generate(
    kAdcChannelCount,
    (_) => BucketAccumulator(bucketSize: bucketSize, numBuckets: numBuckets),
    growable: false,
  );

  /// Per-channel bucket aggregates of the first-difference series
  /// (`diff[j] = raw[j] - raw[j-1]`), same bucket grid as [valueBuckets].
  /// Used by the derivative graph's bucket fast path; the gap/first-sample
  /// diff rule lives in [ingestDiff].
  final List<BucketAccumulator> diffBuckets = List.generate(
    kAdcChannelCount,
    (_) => BucketAccumulator(bucketSize: bucketSize, numBuckets: numBuckets),
    growable: false,
  );

  /// The shared per-sample ingester feeding [valueBuckets]/[diffBuckets]
  /// (see [ChannelIngest]).
  late final List<ChannelIngest> _ingest = List.generate(
    kAdcChannelCount,
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

  /// Factory board calibration read from the device at connect time (parsed
  /// by [AdcPacketDecoder.onCalibrationPacket]). Null until the first
  /// successful read of this run: "no device data" must be representable —
  /// defaulting to nominal values would let the UI present numbers no
  /// hardware ever produced. Conversions require the resolved board
  /// constants ([boardDataStatus]); without them every unit but raw reports
  /// unavailable.
  ///
  /// Identity-free: it describes the samples the hub holds, not the attached
  /// device (the settings page's calibration row shows the flash-document
  /// copy, `RigState.boardCalibration`). Cleared when the link
  /// drops ([clearBoardCalibration]) — a dead stream has no constants.
  BoardCalibration? get boardCalibration => _boardCalibration;
  BoardCalibration? _boardCalibration;

  /// The board-data verdict for the live UI's raw-only notice: the parsed
  /// document's verdict, or [BoardDataStatus.unreadable] before any
  /// successful read and after a link drop (a failed connect-time read never
  /// delivers a document, so absence IS the unreadable verdict).
  BoardDataStatus get boardDataStatus =>
      _boardCalibration?.constantsStatus ?? BoardDataStatus.unreadable;

  /// Human-readable reason behind [boardDataStatus] when not ok.
  String get boardDataDetail => _boardCalibration?.constantsDetail ?? '';

  /// Load cell converting each channel (null = unassigned, electrical units
  /// only). Owned by `RigState` (device slots, including unsaved edits);
  /// pushed here via [updateLoadCells].
  List<LoadCellProfile?> _loadCells = List.filled(kAdcChannelCount, null);

  /// Bumped whenever the calibration set changes (board data or load-cell
  /// assignments); renderers mix it into their segment-cache keys.
  int _calibrationVersion = 0;

  /// Wall-clock time of the most recent malformed (undecodable) ADC packet
  /// the decoder dropped, and that packet's byte length. Read by
  /// [deriveFeedHealth]; reset by [clear].
  DateTime? lastMalformedPacketAt;
  int? lastMalformedPacketLen;

  /// Wall-clock time the current stream's data began accumulating (set by
  /// [clear], which runs on every new device stream). A stream younger than
  /// the feed-health freshness window simply hasn't produced its first
  /// packet yet — [deriveFeedHealth] reads that as "starting", not "silent".
  DateTime? streamStartedAt;

  /// Wall-clock time of the last completed packet batch ([commitBatch]), or
  /// null before the first packet of the stream. The live UI derives a
  /// data-stall indication from this: while the link reports streaming, a
  /// timestamp older than a couple of seconds means the device has gone
  /// silent (firmware hang / marginal link). Reset by [clear].
  @override
  DateTime? lastDataAt;

  /// The 16-bit running sample counter of the most recently decoded packet
  /// (its FIRST sample), paired with the hub index of that same sample —
  /// noted by [AdcPacketDecoder] via [notePacketCounter] after any gap
  /// injection. Together they anchor the device sample counter to the hub
  /// timeline: sample i carries counter
  /// `anchor.counter + (i - anchor.hubIndex)` (past 0xFFFF, i.e. unwrapped).
  /// The recording writer reads this once to latch a session's `ssn_origin`
  /// (docs/csv-format-v1.md); nothing else consumes it. One nullable record
  /// so the pair can never be half-set or half-reset.
  ({int counter, int hubIndex})? packetAnchor;

  /// Note the wire packet counter of the packet whose first sample sits at
  /// the current [totalSamples]. Called by the decoder after gap injection
  /// and before the packet's frames are added. Raw 16-bit value; wrap
  /// adjustment falls out of the pairing with the hub index.
  @override
  void notePacketCounter(int counter) {
    packetAnchor = (counter: counter, hubIndex: totalSamples);
  }

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

  @override
  void addClearedListener(void Function() listener) =>
      _clearedListeners.add(listener);

  void removeClearedListener(void Function() listener) =>
      _clearedListeners.remove(listener);

  DataHub() {
    clear();
  }

  /// Reset every per-stream accumulation: ring position, peaks, tare, gaps
  /// and buckets. Invoked from the constructor and by `StreamResetCoordinator`
  /// each time a new device stream starts, so two connections (or two
  /// devices) never splice into one trace and "Peak" never survives a
  /// disconnect.
  ///
  /// Deliberately does NOT touch [boardCalibration]: a connecting device's
  /// calibration is read during post-connect setup, BEFORE the streaming
  /// transition that triggers this reset. The disconnect side is handled by
  /// [clearBoardCalibration].
  void clear() {
    _tareCount = 0;
    totalSamples = 0;
    _generation++;
    lastMalformedPacketAt = null;
    lastMalformedPacketLen = null;
    streamStartedAt = DateTime.now();
    lastDataAt = null;
    packetAnchor = null;
    gaps.clear();
    for (int i = 0; i < kAdcChannelCount; ++i) {
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

  /// Note a malformed packet the decoder dropped. Deliberately does NOT
  /// notify: malformed packets can arrive at the full notification rate (a
  /// stream where EVERY packet is bad), and the feed-health display
  /// re-derives on its own 1 Hz tick — a per-packet notify would be a
  /// lot of rebuilds.
  @override
  void noteMalformedPacket(int length) {
    lastMalformedPacketAt = DateTime.now();
    lastMalformedPacketLen = length;
  }

  bool get taring => (_tareCount > 0);

  /// Wall-clock deadline for an in-progress tare: a window that stops
  /// filling (device gone silent) would otherwise leave the hub "taring"
  /// forever — recording stays refused and the user gets no completion.
  /// Generous (several window lengths) so a lossy link pausing the average
  /// doesn't abort a legitimate tare. Checked in [commitBatch].
  static const Duration _tareTimeout = Duration(milliseconds: _tareWindow * 5);
  DateTime _tareDeadline = DateTime.fromMillisecondsSinceEpoch(0);

  /// Request a new tare operation (zeros readings using the next N real
  /// samples). The previous offsets stay in effect while the window fills —
  /// zeroing them up front would make live values jump to absolute
  /// (offset-inclusive) readings for a second, then snap back.
  void requestTare() {
    _tareCount = _tareWindow;
    _tareDeadline = DateTime.now().add(_tareTimeout);
    for (int i = 0; i < kAdcChannelCount; ++i) {
      _runningTotal[i] = 0;
    }
    // Notify so observers of [taring] (the TARE button's "TARING" label)
    // flip on the tap rather than on the next packet's [commitBatch].
    notifyListeners();
  }

  /// Append one decoded sample (one value per channel). Samples are always
  /// buffered and [totalSamples] always advances — including while a tare is
  /// in progress, so taring never warps the stream's timeline or punches an
  /// unmarked hole in an ongoing recording. A tare only re-zeros the display
  /// offset: while taring, each real frame is ADDITIONALLY accumulated into
  /// the tare average.
  @override
  void addSampleFrame(Int32List values) {
    assert(values.length >= kAdcChannelCount);
    for (int i = 0; i < kAdcChannelCount; ++i) {
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
  @override
  void addDroppedFrames(int count) {
    final int toInject = math.min(count, maxDataSz);
    gaps.append(totalSamples, totalSamples + toInject);
    for (int d = 0; d < toInject; d++) {
      for (int i = 0; i < kAdcChannelCount; ++i) {
        _addData(_currentRaw[i], i);
      }
      totalSamples++;
    }
  }

  /// Copy the [count] samples starting at logical index [startIdx] out of
  /// the ring, together with everything the session writer needs about the
  /// same span (gap ranges, the packet-counter anchor). This is the
  /// recording path's only read of the ring — [SampleSlice] is the whole
  /// handoff, so the writer never indexes [rawData] itself.
  SampleSlice snapshotRange(int startIdx, int count) {
    return SampleSlice(
      startIndex: startIdx,
      channels: [
        for (int ch = 0; ch < kAdcChannelCount; ++ch)
          Int32List.fromList([
            for (int s = 0; s < count; ++s)
              rawData[ch][(startIdx + s) % maxDataSz],
          ]),
      ],
      gapRanges: gaps.rangesIn(startIdx, startIdx + count).toList(),
      anchor: packetAnchor,
    );
  }

  /// Close out one decoded packet: notify [SamplesAppendedListener]s of the
  /// slice appended since [startIdx] (the caller snapshots [totalSamples]
  /// before decoding) and notify listeners once per packet.
  @override
  void commitBatch(int startIdx) {
    final int count = totalSamples - startIdx;
    if (count > 0) {
      for (final listener in _samplesAppendedListeners) {
        listener(startIdx, count);
      }
    }
    // Abandon a tare whose window stopped filling (device gone silent
    // mid-tare): the pre-tare offsets are still in effect — nothing was
    // zeroed up front — and the user can simply tare again.
    if (taring && DateTime.now().isAfter(_tareDeadline)) {
      _tareCount = 0;
      for (int i = 0; i < kAdcChannelCount; ++i) {
        _runningTotal[i] = 0;
      }
    }
    lastDataAt = DateTime.now();
    gaps.pruneBefore(totalSamples - maxDataSz); // ring-wrap hygiene
    notifyListeners();
  }

  /// Replace the board calibration (a freshly-parsed factory read arrived).
  /// Content-equal updates are a no-op (same rule as [updateLoadCells]): a
  /// reconnect re-reading an identical document must not invalidate the
  /// graph segment caches.
  @override
  void updateBoardCalibration(BoardCalibration calibration) {
    final prev = _boardCalibration;
    if (prev != null && _sameBoardCalibration(prev, calibration)) return;
    _boardCalibration = calibration;
    _calibrationVersion++;
    notifyListeners();
  }

  /// Forget the board calibration. Called when the link drops: the stream it
  /// converted is dead, so conversions degrade to raw counts until the next
  /// connect-time read lands. Safe while a session finalizes — the session
  /// snapshotted its calibration at start; the final flush reads ring data
  /// only. A no-op when already clear.
  void clearBoardCalibration() {
    if (_boardCalibration == null) return;
    _boardCalibration = null;
    _calibrationVersion++;
    notifyListeners();
  }

  /// Content equality for cache invalidation: conversion inputs only.
  /// factoryDate/excitationMv are display metadata. Nominals are conversion
  /// inputs — a nominals-only board must still replace a constants-failed
  /// one (and vice versa).
  static bool _sameBoardCalibration(BoardCalibration a, BoardCalibration b) {
    if (a.constantsStatus != b.constantsStatus) return false;
    for (int i = 0; i < a.channels.length; ++i) {
      final x = a.channels[i];
      final y = b.channels[i];
      if (!_sameNominals(x.nominals, y.nominals)) return false;
      if (!_sameList(x.resistors, y.resistors)) return false;
      if (!_sameList(x.readings, y.readings)) return false;
    }
    return true;
  }

  static bool _sameList(List<double>? a, List<double>? b) {
    if ((a == null) != (b == null)) return false;
    if (a == null || b == null) return true;
    if (a.length != b.length) return false;
    for (int k = 0; k < a.length; ++k) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  static bool _sameNominals(ChannelNominals? a, ChannelNominals? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.adcFsrV == b.adcFsrV &&
        a.afeGain == b.afeGain &&
        a.pgaGain == b.pgaGain &&
        a.excitationV == b.excitationV;
  }

  /// Replace the per-channel load-cell assignments (the rig's slots changed:
  /// flash read, edit, save, revert). Content-equal updates are a no-op so an
  /// unrelated change can't invalidate the graph caches.
  void updateLoadCells(List<LoadCellProfile?> cells) {
    assert(cells.length == kAdcChannelCount);
    var same = _loadCells.length == cells.length;
    for (int i = 0; same && i < cells.length; i++) {
      same = _loadCells[i] == cells[i];
    }
    if (same) return;
    _loadCells = List.of(cells);
    _calibrationVersion++;
    notifyListeners();
  }

  // -- GraphDataSource --------------------------------------------------------

  @override
  int get bufferCapacity => maxDataSz;

  @override
  int get oldestSample =>
      totalSamples > maxDataSz ? totalSamples - maxDataSz : 0;

  @override
  int get sampleRate => sampleRateHz;

  @override
  ChannelCalibration calibrationFor(int channelIndex) => ChannelCalibration(
    // A missing/never-read board leaves the channel with no calibration and
    // no nominals: electrical and force units report unavailable and only
    // raw counts convert — see [boardDataStatus].
    board:
        _boardCalibration?.channels[channelIndex] ?? ChannelBoardCalibration(),
    loadCell: _loadCells[channelIndex],
  );

  @override
  int get calibrationVersion => _calibrationVersion;

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

  /// Latest raw value of a channel (ADC counts), for the live stats' limit
  /// levels — the warning thresholds are evaluated in the raw domain.
  int currentRawFor(int adcChannel) {
    assert(adcChannel >= 0 && adcChannel < kAdcChannelCount);
    return _currentRaw[adcChannel];
  }

  /// Get current value for a given ADC channel in the specified unit. During
  /// a gap this returns the held (last real) value; check [liveEdgeIsGap] to
  /// mark it stale in the UI. Null when the unit is unavailable for the
  /// channel (a force unit without an assigned load cell).
  double? currentValue(int adcChannel, DisplayUnit unit) {
    assert(adcChannel >= 0 && adcChannel < kAdcChannelCount);
    final conv = unit.converterFor(
      calibrationFor(adcChannel),
      tare[adcChannel],
    );
    return conv?.call(_currentRaw[adcChannel].toDouble());
  }

  /// Peak value for a given ADC channel in the specified unit: the max over
  /// the sample window [start, end), converted through the channel's
  /// calibration. The window is clamped to the retained data, so callers may
  /// pass a graph window unclamped; a window holding no retained samples
  /// reports 0, as does an empty stream. Exact and bucket-accelerated (see
  /// [windowedExtremes]). Null when the unit is unavailable for the channel.
  double? peakValue(
    int adcChannel,
    DisplayUnit unit, {
    required int start,
    required int end,
  }) {
    assert(adcChannel >= 0 && adcChannel < kAdcChannelCount);
    if (totalSamples == 0) return 0;
    final conv = unit.converterFor(
      calibrationFor(adcChannel),
      tare[adcChannel],
    );
    if (conv == null) return null;
    final ext = windowedExtremes(
      valueBuckets[adcChannel].series,
      math.max(start, oldestSample),
      math.min(end, totalSamples),
      (i) => rawData[adcChannel][i % maxDataSz].toDouble(),
    );
    return ext == null ? 0 : conv(ext.$2);
  }

  /// Get minimum (most negative) value for a given ADC channel in the
  /// specified unit. Returns 0 before the first sample arrives; null when
  /// the unit is unavailable for the channel.
  double? minValue(int adcChannel, DisplayUnit unit) {
    assert(adcChannel >= 0 && adcChannel < kAdcChannelCount);
    if (totalSamples == 0) return 0;
    final conv = unit.converterFor(
      calibrationFor(adcChannel),
      tare[adcChannel],
    );
    return conv?.call(rawMin[adcChannel].toDouble());
  }

  /// Get the instantaneous derivative (first-difference) for a channel in
  /// unit/s; null when the unit is unavailable for the channel.
  double? currentDerivative(int adcChannel, DisplayUnit unit) {
    assert(adcChannel >= 0 && adcChannel < kAdcChannelCount);
    if (totalSamples < 2) return 0;

    // A held value on either side would fabricate a flat or spiking
    // derivative; report 0 across gap edges instead.
    if (gaps.contains(totalSamples - 1) || gaps.contains(totalSamples - 2)) {
      return 0;
    }

    final conv = unit.converterFor(
      calibrationFor(adcChannel),
      tare[adcChannel],
    );
    if (conv == null) return null;

    final raw1 = rawData[adcChannel][(totalSamples - 1) % maxDataSz];
    final raw2 = rawData[adcChannel][(totalSamples - 2) % maxDataSz];

    // Difference the converter output (not the raw diff): exact under the
    // piecewise map, and tare cancels. Scaled to units per second.
    return (conv(raw1.toDouble()) - conv(raw2.toDouble())) * sampleRateHz;
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
