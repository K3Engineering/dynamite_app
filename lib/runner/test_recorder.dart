import 'package:flutter/foundation.dart';

import '../models/device_profile.dart';
import '../models/display_unit.dart';
import '../services/app_settings.dart';
import '../services/recording_controller.dart';
import '../services/rig_state.dart';

/// Recording side of a test run, as the runner needs it. Production wraps
/// [RecordingController]; tests stub it.
abstract interface class TestRecorder {
  bool get inProgress;
  Listenable get changes;

  TestRecorderStartResult start(String name);
  Future<TestRecorderStopResult> stop();
}

sealed class TestRecorderStartResult {
  const TestRecorderStartResult();
}

final class TestRecorderStarted extends TestRecorderStartResult {
  const TestRecorderStarted();
}

/// Refused before any recording began; [reason] is user-facing.
final class TestRecorderRefused extends TestRecorderStartResult {
  const TestRecorderRefused(this.reason);
  final String reason;
}

sealed class TestRecorderStopResult {
  const TestRecorderStopResult();
}

final class TestRecorderSaved extends TestRecorderStopResult {
  const TestRecorderSaved(this.sessionId, this.name);
  final String sessionId;
  final String name;
}

/// Finalized cleanly but nothing was recorded.
final class TestRecorderNothingRecorded extends TestRecorderStopResult {
  const TestRecorderNothingRecorded();
}

final class TestRecorderFailed extends TestRecorderStopResult {
  const TestRecorderFailed(this.error);
  final Object error;
}

/// The production adapter: one test run owns the app's recording lifecycle.
class RecordingTestRecorder implements TestRecorder {
  RecordingTestRecorder({
    required RecordingController recording,
    required RigState rig,
    required AppSettings settings,
  }) : _recording = recording,
       _rig = rig,
       _settings = settings;

  final RecordingController _recording;
  final RigState _rig;
  final AppSettings _settings;

  @override
  bool get inProgress => _recording.sessionInProgress;

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
  Future<TestRecorderStopResult> stop() async {
    final result = await _recording.stopSession();
    return switch (result) {
      StopSessionSaved(:final sessionId, :final name) => TestRecorderSaved(
        sessionId,
        name,
      ),
      StopSessionNothingRecorded() => const TestRecorderNothingRecorded(),
      StopSessionFailed(:final error) => TestRecorderFailed(error),
      StopSessionRefused() => const TestRecorderNothingRecorded(),
    };
  }
}
