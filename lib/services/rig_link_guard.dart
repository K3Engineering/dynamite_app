import 'package:flutter/foundation.dart';

import 'app_events.dart';
import 'rig_state.dart';

/// Reacts to link-up transitions on behalf of [RigState]: when a link goes
/// away (a user disconnect, an unexpected drop, or a failed post-connect
/// setup), the rig's flash document and unsaved edits die with it, and a
/// pending-edit discard is surfaced. Uses the same narrow notify-plus-poll
/// port as [FeedHealthTracker] and [StreamResetCoordinator]: the source
/// notifies for many reasons (RSSI polls included), and the edge guard keeps
/// this a no-op unless the link actually came or went.
class RigLinkGuard {
  RigLinkGuard({
    required RigState rig,
    required AppEvents events,
    required Listenable linkChanges,
    required bool Function() linkUpNow,
  }) : _rig = rig,
       _events = events,
       _linkChanges = linkChanges,
       _linkUpNow = linkUpNow {
    _linkChanges.addListener(_onLinkChanged);
  }

  final RigState _rig;
  final AppEvents _events;
  final Listenable _linkChanges;
  final bool Function() _linkUpNow;

  bool _wasUp = false;

  void _onLinkChanged() {
    final up = _linkUpNow();
    if (up == _wasUp) return;
    _wasUp = up;
    if (up) return;
    if (_rig.hasPending) _events.emit(const RigEditsDiscarded());
    _rig.onLinkDropped();
  }

  void dispose() => _linkChanges.removeListener(_onLinkChanged);
}
