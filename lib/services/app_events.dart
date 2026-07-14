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

/// A recording's storage writer latched a failure (e.g. disk full / web
/// quota); the saved session may be truncated. Emitted from
/// `RecordingController.stopSession` for both user-initiated and auto stops.
class RecordingStorageError extends AppEvent {
  const RecordingStorageError(this.error);

  final Object error;
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
