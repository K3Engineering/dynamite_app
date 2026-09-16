import 'package:flutter/foundation.dart';

import '../utils/edge_watcher.dart';
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
  }) : _watcher = EdgeWatcher<bool>(
         sources: [streamingChanges],
         now: streamingNow,
         // Seeded "not streaming": a tracker built mid-stream resets the hub
         // on the first notification, like an explicit constructor clear.
         seed: false,
         effect: (streaming) {
           if (streaming) {
             // New device stream. Clear the previous stream's ring buffer,
             // peaks, tare and gaps so two connections never splice into one
             // trace; the decoder restarts continuity itself off the clear
             // (see AdcPacketDecoder's constructor). Runs on stream entry
             // (not on disconnect) so a recording being finalized after an
             // unexpected drop can still flush the data it already
             // snapshotted.
             hub.clear();
           } else {
             hub.clearBoardCalibration();
           }
         },
       );

  final EdgeWatcher<bool> _watcher;

  void dispose() => _watcher.dispose();
}
