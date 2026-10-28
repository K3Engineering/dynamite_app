import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'device_profile.dart';

/// One contiguous run of live samples handed from the live buffer (DataHub)
/// to the session writer, fully snapshotted: the values, the span's
/// dropped-sample ranges, and the packet-counter anchor for origin
/// computation. The writer never reads the live ring — everything it needs
/// is copied here at snapshot time.
@immutable
class const SampleSlice({
  /// Hub-logical index of the first sample in [channels].
  required final int startIndex,

  /// Per-channel sample values, copied out of the ring; element s of
  /// channel ch is the sample at hub-logical index [startIndex] + s.
  required final List<Int32List> channels,

  /// Dropped-sample ranges intersecting the span, hub-logical indices.
  required final List<(int, int)> gapRanges,

  /// The packet-counter anchor at snapshot time (see
  /// `DataHub.notePacketCounter`). Non-null because the recording path only
  /// snapshots a flowing feed; [DataHub.snapshotRange] fails loud otherwise.
  required final ({int counter, int hubIndex}) anchor,
}) {
  this : assert(channels.length == kAdcChannelCount);

  int get sampleCount => channels.first.length;
}
