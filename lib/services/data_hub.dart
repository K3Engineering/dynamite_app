import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/device_profile.dart';
import '../models/bucket_series.dart';
import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';
import '../models/channel_converter.dart';
import '../models/hub_event.dart';
import '../models/load_cell.dart';
import '../models/display_unit.dart';
import '../models/feed_health.dart';
import '../models/gap_list.dart';
import '../models/graph_data_source.dart';
import '../models/sample_slice.dart';
import 'adc_sink.dart';

/// Storage and derived statistics for the live ADC stream.
///
/// Dropped samples are tracked out-of-band in [gaps]; the ring buffer holds
/// the previous sample's value across a gap, so every stored value is a real
/// ADC reading and downstream consumers need no magic-value checks.
///
/// Channel count is [kAdcChannelCount]; channel index == storage index ==
/// display index.
class DataHub extends ChangeNotifier
    implements GraphDataSource, AdcSink, FeedHealthSource {
  /// Ring capacity in samples (~10 min at 1 kHz). A fixed capacity, not derived
  /// from the device rate.
  static const int maxDataSz = 600 * 1000;
  static const int bucketSize = kBucketSize;
  static const int numBuckets = maxDataSz ~/ bucketSize;

  /// The active stream's sample rate (Hz), pushed by the link layer before
  /// streaming. 1000 before any link, a display default; trusted downstream
  /// only after the config readback.
  @override
  int get sampleRateHz => _sampleRateHz;
  int _sampleRateHz = 1000;

  /// Push the sample rate parsed from the device config readback (once per
  /// link, before the feed subscription).
  void setSampleRate(int hz) => _sampleRateHz = hz;

  /// Per-channel tare offset in raw counts; null = no offset. Null is
  /// first-class, not zero counts (the board's physical zero is its dead-short
  /// reading).
  final List<double?> tare = List<double?>.filled(kAdcChannelCount, null);

  /// Latest raw value per channel.
  final Int32List _currentRaw = Int32List(kAdcChannelCount);

  /// Per-channel raw storage, ring-addressed; read through [rawAt].
  final List<Int32List> _rawData = List.generate(
    kAdcChannelCount,
    (_) => Int32List(maxDataSz),
    growable: false,
  );

  /// Per-channel bucket aggregates of the raw values; see [valueBucketsFor].
  final List<BucketAccumulator> _valueBuckets = List.generate(
    kAdcChannelCount,
    (_) => BucketAccumulator(bucketSize: bucketSize, numBuckets: numBuckets),
    growable: false,
  );

  /// Per-channel bucket aggregates of the first differences; see
  /// [diffBucketsFor] and [ingestDiff].
  final List<BucketAccumulator> _diffBuckets = List.generate(
    kAdcChannelCount,
    (_) => BucketAccumulator(bucketSize: bucketSize, numBuckets: numBuckets),
    growable: false,
  );

  /// The shared per-sample ingester (see [ChannelIngest]).
  late final List<ChannelIngest> _ingest = List.generate(
    kAdcChannelCount,
    (i) => ChannelIngest(
      valueBuckets: _valueBuckets[i],
      diffBuckets: _diffBuckets[i],
      gaps: gaps,
    ),
    growable: false,
  );

  /// The in-progress tare window: how many real samples its average spans and
  /// which channel (null = all). Nothing accumulates while it fills; completion
  /// scans the window back out of the ring.
  _PendingTare? _pendingTare;

  @override
  int totalSamples = 0;

  /// Factory board calibration read at connect time; null until the first
  /// successful read. Identity-free: it describes the samples the hub holds,
  /// not the attached device. Cleared when the link drops.
  BoardCalibration? get boardCalibration => _boardCalibration;
  BoardCalibration? _boardCalibration;

  /// Load cell per channel (null = unassigned). Owned by `RigState`, pushed via
  /// [updateLoadCells].
  List<LoadCellProfile?> _loadCells = List.filled(kAdcChannelCount, null);

  /// Bumped whenever the calibration set changes (board data or load-cell
  /// assignments); renderers mix it into their segment-cache keys.
  int _calibrationVersion = 0;

  /// Bumped whenever a tare offset changes (window commit, reset, manual
  /// set, stream reset). See `ChannelConversion.tareVersion`.
  int _tareVersion = 0;

  /// Time and byte length of the most recent malformed packet the decoder
  /// dropped; reset by [clear].
  @override
  DateTime? lastMalformedPacketAt;
  int? lastMalformedPacketLen;

  /// When the current stream began accumulating (set by [clear]).
  @override
  DateTime? streamStartedAt;

  /// Time of the last completed packet batch ([commitBatch]); null before the
  /// first. Reset by [clear].
  @override
  DateTime? lastDataAt;

  /// The 16-bit running sample counter of the most recently decoded packet's
  /// first sample, paired with the hub index of that sample, to anchor the
  /// counter to the hub timeline (unwrapped past 0xFFFF). Read once to latch a
  /// session's `ssn_origin`.
  ({int counter, int hubIndex})? packetAnchor;

  /// Note the wire packet counter for the packet whose first sample sits at the
  /// current [totalSamples] (raw 16-bit).
  @override
  void notePacketCounter(int counter) {
    packetAnchor = (counter: counter, hubIndex: totalSamples);
  }

  /// Monotonic counter bumped by [clear], distinguishing "same stream, more
  /// data" from "a new stream reset the hub".
  int _generation = 0;
  int get generation => _generation;

  /// Sample ranges lost to dropped BLE packets; the ring holds the previous
  /// value across them.
  @override
  final GapList gaps = GapList();

  /// Observers of the hub's event stream (see `hub_event.dart`). [ObserverList]
  /// keeps removal-during-dispatch safe.
  final ObserverList<void Function(HubEvent)> _eventListeners =
      ObserverList<void Function(HubEvent)>();

  @override
  void addEventListener(void Function(HubEvent) listener) =>
      _eventListeners.add(listener);

  @override
  void removeEventListener(void Function(HubEvent) listener) =>
      _eventListeners.remove(listener);

  void _emit(HubEvent event) {
    for (final listener in _eventListeners) {
      listener(event);
    }
  }

  DataHub() {
    clear();
  }

  /// Reset every per-stream accumulation (ring, peaks, tare, gaps, buckets).
  /// Runs from the constructor and on each new device stream, so two
  /// connections never splice into one trace. Does NOT touch
  /// [boardCalibration] (read before the streaming reset; the disconnect side
  /// is [clearBoardCalibration]).
  void clear() {
    _pendingTare = null;
    totalSamples = 0;
    _generation++;
    lastMalformedPacketAt = null;
    lastMalformedPacketLen = null;
    streamStartedAt = DateTime.now();
    lastDataAt = null;
    packetAnchor = null;
    gaps.clear();
    for (int i = 0; i < kAdcChannelCount; ++i) {
      tare[i] = null;
      _currentRaw[i] = 0;
      _ingest[i].reset();
    }
    _tareVersion++;
    _emit(const HubCleared());
    notifyListeners();
  }

  /// Note a malformed packet the decoder dropped. Does NOT notify: these can
  /// arrive per packet and the feed-health display re-derives on its own tick.
  @override
  void noteMalformedPacket(int length) {
    lastMalformedPacketAt = DateTime.now();
    lastMalformedPacketLen = length;
  }

  bool get taring => _pendingTare != null;

  /// Wall-clock deadline for an in-progress tare, so a silent device can't
  /// leave the hub "taring" forever. 5x the 1 s window (see [requestTare]);
  /// checked in [commitBatch].
  static const Duration _tareTimeout = Duration(seconds: 5);
  DateTime _tareDeadline = DateTime.fromMillisecondsSinceEpoch(0);

  /// Request a tare (zeros readings using the next second of real samples) for
  /// one [channel] or all. One second at any rate: the downsampler flattens
  /// higher-rate noise to the same floor. A new request replaces an
  /// in-progress one; previous offsets stay in effect while the window fills.
  void requestTare({int? channel}) {
    assert(channel == null || (channel >= 0 && channel < kAdcChannelCount));
    _pendingTare = _PendingTare(_sampleRateHz, channel);
    _tareDeadline = DateTime.now().add(_tareTimeout);
    // Notify so [taring] observers flip on the tap, not the next batch.
    notifyListeners();
  }

  /// Abort an in-progress tare without committing.
  void _cancelPendingTare() => _pendingTare = null;

  /// Drop tare offsets (back to gross) for one [channel] or all.
  void resetTare({int? channel}) {
    assert(channel == null || (channel >= 0 && channel < kAdcChannelCount));
    _cancelPendingTare();
    for (int i = 0; i < kAdcChannelCount; ++i) {
      if (channel == null || channel == i) tare[i] = null;
    }
    _tareVersion++;
    notifyListeners();
  }

  /// Write one channel's tare offset directly, in counts; absolute.
  void setTareOffset(int channel, double rawValue) {
    assert(channel >= 0 && channel < kAdcChannelCount);
    assert(rawValue.isFinite);
    _cancelPendingTare();
    tare[channel] = rawValue;
    _tareVersion++;
    notifyListeners();
  }

  /// A window's worth of real samples has arrived: their mean becomes the
  /// offset, scanned back out of the ring and skipping gap (held) samples.
  void _commitTare(_PendingTare window) {
    final sums = Float64List(kAdcChannelCount);
    int found = 0;
    for (
      int i = totalSamples - 1;
      found < window.length; // ends at the request index at the latest
      i--
    ) {
      if (gaps.contains(i)) continue; // held value: not a reading
      for (int ch = 0; ch < kAdcChannelCount; ++ch) {
        sums[ch] += rawAt(ch, i);
      }
      found++;
    }
    for (int ch = 0; ch < kAdcChannelCount; ++ch) {
      if (window.channel == null || window.channel == ch) {
        tare[ch] = sums[ch] / window.length;
      }
    }
    _pendingTare = null;
    _tareVersion++;
  }

  /// Append one decoded sample (one value per channel); [totalSamples] always
  /// advances, even while a tare window fills.
  @override
  void addSampleFrame(Int32List values) {
    assert(values.length >= kAdcChannelCount);
    for (int i = 0; i < kAdcChannelCount; ++i) {
      final int val = values[i];
      _currentRaw[i] = val;
      _addData(val, i);
    }
    totalSamples++;

    final pending = _pendingTare;
    if (pending != null && --pending.remaining == 0) {
      _commitTare(pending);
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

  /// Copy the [count] samples at [startIdx] out of the ring with the span's gap
  /// ranges and packet-counter anchor ([SampleSlice]). Throws when no anchor
  /// was noted (a recording only latches on a flowing feed).
  SampleSlice snapshotRange(int startIdx, int count) {
    final anchor = packetAnchor;
    if (anchor == null) {
      throw StateError(
        'snapshotRange without a packet anchor — no decodable data flowed '
        '(the StartSessionNoData guard was bypassed)',
      );
    }
    return SampleSlice(
      startIndex: startIdx,
      channels: [
        for (int ch = 0; ch < kAdcChannelCount; ++ch)
          Int32List.fromList([
            for (int s = 0; s < count; ++s) rawAt(ch, startIdx + s),
          ]),
      ],
      gapRanges: gaps.rangesIn(startIdx, startIdx + count).toList(),
      anchor: anchor,
    );
  }

  /// Close out a decoded packet: emit [HubBatchAppended] for the slice since
  /// [startIdx] and notify once.
  @override
  void commitBatch(int startIdx) {
    final int count = totalSamples - startIdx;
    if (count > 0) {
      _emit(HubBatchAppended(startIdx, count));
    }
    // Abandon a tare whose window stopped filling; the pre-tare offsets are
    // still in effect and the user can retry.
    if (taring && DateTime.now().isAfter(_tareDeadline)) {
      _pendingTare = null;
    }
    lastDataAt = DateTime.now();
    gaps.pruneBefore(totalSamples - maxDataSz); // ring-wrap hygiene
    notifyListeners();
  }

  /// Replace the board calibration. Content-equal updates are a no-op so a
  /// reconnect re-reading identical data doesn't invalidate the graph caches.
  @override
  void updateBoardCalibration(BoardCalibration calibration) {
    final prev = _boardCalibration;
    if (prev != null && _sameBoardCalibration(prev, calibration)) return;
    _boardCalibration = calibration;
    _calibrationVersion++;
    notifyListeners();
  }

  /// Forget the board calibration on link drop; conversions degrade to raw
  /// until the next read. Safe while a session finalizes (it snapshotted at
  /// start). A no-op when already clear.
  void clearBoardCalibration() {
    if (_boardCalibration == null) return;
    _boardCalibration = null;
    _calibrationVersion++;
    notifyListeners();
  }

  /// Content equality for cache invalidation: conversion inputs only
  /// (cal metadata and the raw KVS provenance are display-only).
  static bool _sameBoardCalibration(BoardCalibration a, BoardCalibration b) =>
      switch ((a, b)) {
        (UnprovisionedBoardCalibration(), UnprovisionedBoardCalibration()) =>
          true,
        (final InvalidBoardCalibration a, final InvalidBoardCalibration b) =>
          a.detail == b.detail,
        (
          final ProvisionedBoardCalibration pa,
          final ProvisionedBoardCalibration pb,
        ) =>
          _sameChannels(pa.channels, pb.channels),
        _ => false,
      };

  static bool _sameChannels(
    List<ChannelBoardCalibration> a,
    List<ChannelBoardCalibration> b,
  ) {
    for (int i = 0; i < a.length; ++i) {
      final x = a[i];
      final y = b[i];
      if (x case final CalibratedChannelBoard xd) {
        if (y is! CalibratedChannelBoard) return false;
        if (!_sameList(xd.resistors, y.resistors)) return false;
        if (!_sameList(xd.readings, y.readings)) return false;
      } else if (y is CalibratedChannelBoard) {
        return false;
      }
      if (!_sameNominals(x.nominals, y.nominals)) return false;
    }
    return true;
  }

  static bool _sameList(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (int k = 0; k < a.length; ++k) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  static bool _sameNominals(ChannelNominals a, ChannelNominals b) {
    if (identical(a, b)) return true;
    return a.adcFsrV == b.adcFsrV &&
        a.afeGain == b.afeGain &&
        a.pgaGain == b.pgaGain &&
        a.excitationV == b.excitationV;
  }

  /// Replace the load-cell assignments. Content-equal updates are a no-op.
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
  int get oldestSample =>
      totalSamples > maxDataSz ? totalSamples - maxDataSz : 0;

  @override
  int get sampleRate => sampleRateHz;

  @override
  int rawAt(int channelIndex, int index) =>
      _rawData[channelIndex][index % maxDataSz];

  @override
  ChannelConverter converterFor(int channelIndex) =>
      ChannelConverter(calibrationFor(channelIndex), tare[channelIndex]);

  @override
  ChannelCalibration calibrationFor(int channelIndex) => ChannelCalibration(
    // Missing document and unprovisioned board alike leave no board map: only
    // raw counts convert.
    board: switch (_boardCalibration) {
      final ProvisionedBoardCalibration b => b.channels[channelIndex],
      _ => null,
    },
    loadCell: _loadCells[channelIndex],
  );

  @override
  UnitAvailability get unitAvailability =>
      resolveUnitAvailability(calibrationFor);

  @override
  int get calibrationVersion => _calibrationVersion;

  @override
  int get tareVersion => _tareVersion;

  @override
  Listenable get repaint => this;

  /// Stream identity for the graph caches; bumped by [clear].
  @override
  int get dataGeneration => _generation;

  @override
  BucketSeries valueBucketsFor(int channelIndex) =>
      _valueBuckets[channelIndex].series;

  @override
  BucketSeries diffBucketsFor(int channelIndex) =>
      _diffBuckets[channelIndex].series;

  @override
  (double, double)? channelExtremes(int channelIndex) {
    final ext = _ingest[channelIndex].extremes;
    return ext == null ? null : (ext.$1.toDouble(), ext.$2.toDouble());
  }

  /// Whether the newest sample is a held (dropped) value.
  bool get liveEdgeIsGap => gaps.contains(totalSamples - 1);

  /// Latest raw value (ADC counts) of a channel, for limit levels.
  int currentRawFor(int adcChannel) {
    assert(adcChannel >= 0 && adcChannel < kAdcChannelCount);
    return _currentRaw[adcChannel];
  }

  /// Current value of [adcChannel] in [unit]; a held value during a gap (see
  /// [liveEdgeIsGap]). Null when the unit is unavailable.
  double? currentValue(int adcChannel, DisplayUnit unit) {
    assert(adcChannel >= 0 && adcChannel < kAdcChannelCount);
    return converterFor(
      adcChannel,
    ).net(unit, _currentRaw[adcChannel].toDouble());
  }

  /// The tare amount being zeroed out, in [unit]. Null when unavailable.
  double? tareOffset(int adcChannel, DisplayUnit unit) {
    assert(adcChannel >= 0 && adcChannel < kAdcChannelCount);
    return converterFor(adcChannel).tareOffset(unit);
  }

  /// Peak of [adcChannel] in [unit] over [start, end), clamped to retention and
  /// bucket-accelerated. Null when the unit is unavailable or the window holds
  /// no sample.
  double? peakValue(
    int adcChannel,
    DisplayUnit unit, {
    required int start,
    required int end,
  }) {
    assert(adcChannel >= 0 && adcChannel < kAdcChannelCount);
    final conv = converterFor(adcChannel).netMap(unit);
    if (conv == null) return null;
    final ext = windowedRawExtremes(adcChannel, start, end);
    return ext == null ? null : conv(ext.$2);
  }

  /// Instantaneous derivative (first difference) of [adcChannel] in unit/s;
  /// null when the unit is unavailable.
  double? currentDerivative(int adcChannel, DisplayUnit unit) {
    assert(adcChannel >= 0 && adcChannel < kAdcChannelCount);
    if (totalSamples < 2) return 0;

    // A held value on either side would fabricate a flat or spiking
    // derivative; report 0 across gap edges instead.
    if (!diffDefinedAt(totalSamples - 1)) return 0;

    final conv = converterFor(adcChannel).netMap(unit);
    if (conv == null) return null;

    // Difference the converter output (not the raw diff): exact under the
    // piecewise map, and tare cancels. Scaled to units/second.
    return (conv(rawAt(adcChannel, totalSamples - 1).toDouble()) -
            conv(rawAt(adcChannel, totalSamples - 2).toDouble())) *
        sampleRateHz;
  }

  void _addData(int val, int idx) {
    // The previous-value read is safe for totalSamples == 0 (Dart % is
    // non-negative) and ignored by the ingest diff rule there.
    final int prev = rawAt(idx, totalSamples - 1);
    _rawData[idx][totalSamples % maxDataSz] = val;
    _ingest[idx].add(totalSamples, val, prev);
  }
}

/// The in-progress tare window: [remaining] counts real frames down to the
/// commit; [length] is the window size, captured at request time.
class _PendingTare {
  _PendingTare(this.length, this.channel) : remaining = length;

  final int length;
  final int? channel;
  int remaining;
}
