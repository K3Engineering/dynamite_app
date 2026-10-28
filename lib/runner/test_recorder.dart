import 'package:flutter/foundation.dart';

import '../models/device_profile.dart';
import '../models/display_unit.dart';
import '../services/app_settings.dart';
import '../services/recording_controller.dart';
import '../services/rig_state.dart';

/// Recording side of a test run, as the runner needs it. Production wraps
/// [RecordingController]; tests stub it.
abstract interface class TestRecorder {
  /// True from a committed start until finalization completes, the stopping
  /// window included.
  bool get inProgress;

  /// True only while samples are still being written: false once a stop (the
  /// runner's, Live's, a storage error, a stream death) has begun, even
  /// though [inProgress] stays true through the finalize flush. Rep detection
  /// must not append to a recording that no longer accepts samples.
  bool get acceptingData;

  Listenable get changes;

  /// Outcome of the most recent finalized stop, whoever triggered it
  /// (the runner, Live's STOP, or an automatic stop). Latched before
  /// [inProgress] clears, so `!inProgress` after a stop means this is set.
  TestRecorderStopResult? get lastStop;

  TestRecorderStartResult start(String name);
  Future<TestRecorderStopResult> stop();
}

sealed class TestRecorderStartResult {
  const new();
}

final class TestRecorderStarted extends TestRecorderStartResult {
  const new();
}

/// Refused before any recording began; [reason] is user-facing.
final class TestRecorderRefused extends TestRecorderStartResult {
  const new(this.reason);
  final String reason;
}

sealed class TestRecorderStopResult {
  const new();
}

final class TestRecorderSaved extends TestRecorderStopResult {
  const new(this.sessionId, this.name);
  final String sessionId;
  final String name;
}

/// Finalized cleanly but nothing was recorded.
final class TestRecorderNothingRecorded extends TestRecorderStopResult {
  const new();
}

final class TestRecorderFailed extends TestRecorderStopResult {
  const new(this.error, {this.sessionId});

  final Object error;

  /// Set when data had reached storage before the failure — the session
  /// exists on disk, possibly truncated (lists as interrupted).
  final String? sessionId;
}

/// [stop] found no recording to stop: a stop the runner didn't start is
/// already finalizing (a storage-error auto-stop, or a race with an external
/// stop). The caller waits for [inProgress] to clear and reads [lastStop].
final class TestRecorderAlreadyFinalizing extends TestRecorderStopResult {
  const new();
}

/// The production adapter: one test run owns the app's recording lifecycle.
class RecordingTestRecorder implements TestRecorder {
  new({required this._recording, required this._rig, required this._settings});

  final RecordingController _recording;
  final RigState _rig;
  final AppSettings _settings;

  @override
  bool get inProgress => _recording.sessionInProgress;

  @override
  bool get acceptingData => _recording.acceptingData;

  @override
  Listenable get changes => _recording;

  @override
  TestRecorderStartResult start(String name) {
    final result = _recording.startSession(
      name: name,
      channelLabels: _rig.channelTitles,
      // Sessions are raw-only: the journal's strict length check wants the
      // hardware channels, not the derived-tail settings list.
      visibleChannels: _settings.activeChannels.sublist(0, kAdcChannelCount),
      // Tests are plate tests: metric spaces are kgf.
      displayUnit: DisplayUnit.kgf,
    );
    return switch (result) {
      StartSessionOk() => const TestRecorderStarted(),
      StartSessionBusy() => const TestRecorderRefused(
        'A recording is already running.',
      ),
      StartSessionTareInProgress() => const TestRecorderRefused(
        'Taring was still in progress — try again.',
      ),
      StartSessionNoData() => const TestRecorderRefused(
        'No data from the plate — check the connection.',
      ),
    };
  }

  @override
  TestRecorderStopResult? get lastStop => switch (_recording.lastStopResult) {
    null => null,
    final result => _mapStop(result),
  };

  TestRecorderStopResult _mapStop(StopSessionResult result) => switch (result) {
    StopSessionSaved(:final sessionId, :final name) => TestRecorderSaved(
      sessionId,
      name,
    ),
    StopSessionNothingRecorded() => const TestRecorderNothingRecorded(),
    StopSessionFailed(:final error, :final sessionId) => TestRecorderFailed(
      error,
      sessionId: sessionId,
    ),
    StopSessionRefused() => const TestRecorderAlreadyFinalizing(),
  };

  @override
  Future<TestRecorderStopResult> stop() async =>
      _mapStop(await _recording.stopSession());
}
