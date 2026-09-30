import 'package:flutter/foundation.dart';

import '../models/hub_event.dart';
import 'data_hub.dart';

/// The user-initiated monitoring pause (the Live tab's pause control).
///
/// The device keeps streaming and the decoder keeps parsing, but paused
/// packets are discarded at the decoder gate (see `AdcPacketDecoder`'s
/// isPaused), so the hub's retained window freezes: everything up to the
/// pause point stays inspectable past the ring's ~10-minute lifetime. The
/// link itself is untouched — link state, wakelock, and RSSI keep reporting
/// normally, which the status bar reflects (a pause is not a device event).
///
/// Pausing and recording are mutually exclusive (enforced by the Live tab's
/// action row): a session that silently lost the paused span would be a
/// dishonest artifact.
class MonitorPause extends ChangeNotifier {
  MonitorPause(this._hub) {
    _hub.addEventListener(_onHubEvent);
  }

  final DataHub _hub;

  bool _paused = false;
  bool get paused => _paused;

  /// Freeze the buffer where it is. The freeze point gets a one-sample gap:
  /// without it the renderer would join the pre-pause and post-resume traces
  /// with a straight line across the discarded span. One sample because it
  /// breaks the polyline (and, via the held value, grays the stats table's
  /// live row as stale for the pause's duration) while staying sub-pixel.
  void pause() {
    if (_paused) return;
    _paused = true;
    if (_hub.totalSamples > 0) _hub.addDroppedFrames(1);
    notifyListeners();
  }

  /// Let packets through again. The frozen buffer stays put; new data
  /// appends after the pause marker.
  void resume() {
    if (!_paused) return;
    _paused = false;
    notifyListeners();
  }

  /// A stream reset erased the buffer the freeze was protecting: nothing
  /// left to pause.
  void _onHubEvent(HubEvent event) {
    if (event is HubCleared) resume();
  }
}
