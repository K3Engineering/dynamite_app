import 'dart:async';

/// One-shot app-level events that some screen-independent producer (BLE link
/// state machine, recording lifecycle) needs to surface to the user, no matter
/// which tab happens to be mounted. Consumed once, at the shell level
/// (see `AppShellState`), which turns them into SnackBars.
sealed class AppEvent {
  const AppEvent();
}

/// A disconnect gave up after [BleLinkManager.disconnectTimeout] without the
/// link returning to idle.
class BleDisconnectTimeout extends AppEvent {
  const BleDisconnectTimeout(this.deviceName);

  /// The affected device's display name (or id).
  final String deviceName;
}

/// A connection dropped or failed during post-connect setup (e.g. the device
/// disappeared mid service-discovery).
class BleConnectionFailed extends AppEvent {
  const BleConnectionFailed(this.deviceName);

  /// The affected device's display name (or id).
  final String deviceName;
}

/// The link dropped unexpectedly while it was up (setting up, starting the
/// data stream, or streaming) — i.e. NOT a user-requested disconnect and not
/// a post-connect setup failure (those surface as [BleConnectionFailed]). A
/// recording in progress is finalized by `RecordingController` when this
/// happens.
class BleConnectionLost extends AppEvent {
  const BleConnectionLost(this.deviceName);

  /// The affected device's display name (or id).
  final String deviceName;
}

/// A recording's storage writer latched a failure (e.g. disk full / web
/// quota); the saved session may be truncated. Emitted from
/// `RecordingController.stopSession` for both user-initiated and auto stops.
class RecordingStorageError extends AppEvent {
  const RecordingStorageError(this.error);

  final Object error;
}

/// The session store could not be opened at startup: on web, the browser
/// failed the recording-capability probe (safe recording is impossible
/// there); on native, the sessions root itself is unreachable. The store
/// stays broken for the app's lifetime — every listing, read and recording
/// fails the same way — so this is the one deliberate surfacing of that
/// verdict. Emitted once from `main`'s recovery call.
class SessionStorageUnavailable extends AppEvent {
  const SessionStorageUnavailable(this.error);

  final Object error;
}

/// The link ended with unsaved load cell edits in flight; they were
/// discarded (unsaved rig edits die with the link — see `RigState`).
class RigEditsDiscarded extends AppEvent {
  const RigEditsDiscarded();
}

/// The device's calibration characteristic could not be read; the app runs
/// on nominal values (no factory calibration) until a read succeeds.
class CalibrationUnreadable extends AppEvent {
  const CalibrationUnreadable(this.deviceName);

  final String deviceName;
}

/// Fire-and-forget event bus for [AppEvent]s.
///
/// App-lifetime singleton created in `main()` (never disposed) and handed to
/// producers by constructor. Broadcast so a remounted shell can re-subscribe;
/// events emitted while nobody listens are dropped, which is fine — nothing
/// emits before the first frame.
class AppEvents {
  final StreamController<AppEvent> _controller =
      StreamController<AppEvent>.broadcast();

  Stream<AppEvent> get stream => _controller.stream;

  void emit(AppEvent event) => _controller.add(event);
}
