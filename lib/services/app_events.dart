import 'dart:async';

import 'package:meta/meta.dart';

/// One-shot app-level events that some screen-independent producer (BLE link
/// state machine, recording lifecycle) needs to surface to the user, no matter
/// which tab happens to be mounted. Consumed once, at the shell level
/// (see `AppShellState`), which turns them into SnackBars.
@immutable
sealed class AppEvent {
  const new();
}

/// A disconnect gave up after [BleLinkManager.disconnectTimeout] without the
/// link returning to idle.
class const BleDisconnectTimeout(
  /// The affected device's display name (or id).
  final String deviceName,
) extends AppEvent;

/// A connection dropped or failed during post-connect setup. The exact reason
/// is on the link manager (see `BleLinkManager.outcomeFor`) for the row;
/// this event only names the device for a short toast.
class const BleConnectionFailed(
  /// The affected device's display name (or id).
  final String deviceName,
) extends AppEvent;

/// The link dropped unexpectedly while up (setting up, starting the stream, or
/// streaming) — not a user disconnect and not a setup failure (those are
/// [BleConnectionFailed]). A recording in progress is finalized when this
/// happens.
class const BleConnectionLost(
  /// The affected device's display name (or id).
  final String deviceName,
) extends AppEvent;

/// A recording's storage writer latched a failure (e.g. disk full / web
/// quota); the saved session may be truncated. Emitted from
/// `RecordingController.stopSession` for both user-initiated and auto stops.
class const RecordingStorageError(final Object error) extends AppEvent;

/// Unsaved load cell edits were discarded: the link ended with edits in
/// flight, or a flash document replaced the one they were seeded from (see
/// `RigState.onFlashRead`).
class const RigEditsDiscarded() extends AppEvent;

/// A flashed release's tag was confirmed on the device after its post-flash
/// reboot (see [FirmwareUpdateService.noteFlashAccepted]). The mismatch
/// direction needs no event of its own: that connect's release check leaves
/// [FirmwareUpdateService.checkState] differing, which the persistent update
/// indicators read.
class const FirmwareFlashVerified(
  /// The firmware git-describe the device now reports.
  final String describe,
) extends AppEvent;

/// Fire-and-forget event bus for [AppEvent]s. App-lifetime singleton created in
/// `main()`; broadcast so a remounted shell can re-subscribe. Events emitted
/// with no listener are dropped (nothing emits before the first frame).
class AppEvents {
  final StreamController<AppEvent> _controller =
      StreamController<AppEvent>.broadcast();

  Stream<AppEvent> get stream => _controller.stream;

  void emit(AppEvent event) => _controller.add(event);
}
