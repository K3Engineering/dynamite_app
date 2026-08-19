import 'dart:typed_data';

import '../models/board_calibration.dart';

/// The decoded-ADC-feed destination consumed by `AdcPacketDecoder`;
/// implemented by `DataHub`. The protocol decoder owns this contract so the
/// lowest-level packet parser never depends on the live-data hub above it.
abstract interface class AdcSink {
  /// Total number of logical samples written so far (the decoder uses this
  /// as the start index of the batch it is about to append).
  int get totalSamples;

  /// The active stream's sample rate (Hz), from the device config readback
  /// — the decoder's counter/clock continuity cross-check counts elapsed
  /// time in samples at this rate.
  int get sampleRateHz;

  /// Anchor the device's packet counter to the sink's timeline (the session
  /// writer derives ssn_origin from this pairing).
  void notePacketCounter(int counter);

  void noteMalformedPacket(int length);

  /// Inject [count] held-value samples for a detected packet gap.
  void addDroppedFrames(int count);

  /// Append one channel-count frame; the sink copies out of [values]
  /// synchronously, so the caller may reuse its buffer.
  void addSampleFrame(Int32List values);

  /// Notify observers that samples `[startIdx, totalSamples)` were appended.
  void commitBatch(int startIdx);

  void updateBoardCalibration(BoardCalibration calibration);

  void addClearedListener(void Function() listener);
}
