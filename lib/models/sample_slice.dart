import 'dart:typed_data';

import 'device_profile.dart';

/// One contiguous run of live samples handed from the live buffer (DataHub)
/// to the session writer, fully snapshotted: the values, the span's
/// dropped-sample ranges, and the packet-counter anchor for origin
/// computation. The writer never reads the live ring — everything it needs
/// is copied here at snapshot time.
class SampleSlice {
  SampleSlice({
    required this.startIndex,
    required this.channels,
    required this.gapRanges,
    required this.anchor,
  }) : assert(channels.length == kAdcChannelCount);

  /// Hub-logical index of the first sample in [channels].
  final int startIndex;

  /// Per-channel sample values, copied out of the ring; element s of
  /// channel ch is the sample at hub-logical index [startIndex] + s.
  final List<Int32List> channels;

  /// Dropped-sample ranges intersecting the span, hub-logical indices.
  final List<(int, int)> gapRanges;

  /// The packet-counter anchor at snapshot time (see
  /// `DataHub.notePacketCounter`).
  final ({int counter, int hubIndex})? anchor;

  int get sampleCount => channels.first.length;
}
