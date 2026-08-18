import 'package:flutter/foundation.dart';

import 'data_hub.dart';

/// Owns the hub resets tied to connection transitions, so recording doesn't
/// have to: a freshly started stream clears the previous stream's live
/// state, and a dropped link forgets the dead device's board calibration.
/// Constructed once in main; listens through the same narrow stream-liveness
/// port shape [FeedHealthTracker] uses (a notify source plus a poll
/// closure), so it never depends on the link layer's concrete type.
class StreamResetCoordinator {
  StreamResetCoordinator({
    required DataHub hub,
    /// Notifies when the stream's liveness may have changed; polled via
    /// [streamingNow]. main wires the link manager in.
    required Listenable streamingChanges,
    required bool Function() streamingNow,
  }) : _hub = hub,
       _streamingChanges = streamingChanges,
       _streamingNow = streamingNow {
    _streamingChanges.addListener(_onStreamingChanged);
  }

  final DataHub _hub;
  final Listenable _streamingChanges;
  final bool Function() _streamingNow;

  /// Liveness at the previous [_onStreamingChanged] notification, for edge
  /// detection (the source may notify for other reasons, e.g. RSSI polls).
  bool _wasStreaming = false;

  void _onStreamingChanged() {
    final streaming = _streamingNow();
    if (streaming == _wasStreaming) return;
    _wasStreaming = streaming;
    if (streaming) {
      // New device stream. Clear the previous stream's ring buffer, peaks,
      // tare and gaps so two connections never splice into one trace; the
      // decoder restarts continuity itself off the clear (see
      // AdcPacketDecoder's constructor). Runs on stream entry (not on
      // disconnect) so a recording being finalized after an unexpected drop
      // can still flush the data it already snapshotted.
      _hub.clear();
    } else {
      _hub.clearBoardCalibration();
    }
  }

  void dispose() => _streamingChanges.removeListener(_onStreamingChanged);
}
