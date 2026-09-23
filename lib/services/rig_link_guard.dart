import 'package:flutter/foundation.dart';

import '../utils/edge_watcher.dart';
import 'rig_state.dart';

/// Reacts to link-up transitions on behalf of [RigState]: when a link goes
/// away (a user disconnect, an unexpected drop, or a failed post-connect
/// setup), the rig's flash document and unsaved edits die with it (the
/// discard of the latter is surfaced by [RigState.onLinkDropped]). Uses the
/// same narrow notify-plus-poll port as [FeedHealthTracker] and
/// [StreamResetCoordinator].
class RigLinkGuard {
  RigLinkGuard({
    required RigState rig,
    required Listenable linkChanges,
    required bool Function() linkUpNow,
  }) : _watcher = EdgeWatcher<bool>(
         sources: [linkChanges],
         now: linkUpNow,
         seed: false,
         effect: (up) {
           if (up) return;
           rig.onLinkDropped();
         },
       );

  final EdgeWatcher<bool> _watcher;

  void dispose() => _watcher.dispose();
}
