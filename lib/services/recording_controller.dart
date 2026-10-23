import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_events.dart';
import 'data_hub.dart';
import 'live_session_writer.dart';
import 'session_store.dart';
import '../models/device_flash.dart';
import '../models/device_profile.dart';
import '../models/display_unit.dart';
import '../models/feed_health.dart';
import '../models/hub_event.dart';
import '../utils/format.dart';

/// Outcome of [RecordingController.startSession].
@immutable
sealed class StartSessionResult {
  const StartSessionResult();
}

/// The session is recording.
final class StartSessionOk extends StartSessionResult {
  const StartSessionOk();
}

/// Refused: another lifecycle operation is already in flight (one outstanding
/// operation at a time).
final class StartSessionBusy extends StartSessionResult {
  const StartSessionBusy();
}

/// Refused: a tare is still averaging, so recording now would freeze the
/// pre-tare offsets for the session's lifetime. Transient.
final class StartSessionTareInProgress extends StartSessionResult {
  const StartSessionTareInProgress();
}

/// Refused: no decodable data is flowing (see [deriveFeedHealth]), so the
/// session would record nothing. Transient.
final class StartSessionNoData extends StartSessionResult {
  const StartSessionNoData();
}

/// Outcome of [RecordingController.stopSession].
@immutable
sealed class StopSessionResult {
  const StopSessionResult();
}

/// Refused: no recording was in progress.
final class StopSessionRefused extends StopSessionResult {
  const StopSessionRefused();
}

/// Finalized cleanly, but nothing was ever recorded (no session directory was
/// created).
final class StopSessionNothingRecorded extends StopSessionResult {
  const StopSessionNothingRecorded(this.name);

  final String name;
}

/// Finalized cleanly to disk.
final class StopSessionSaved extends StopSessionResult {
  const StopSessionSaved(this.sessionId, this.name);

  final String sessionId;
  final String name;
}

/// Finalization failed (a latched write error or a finalize-step throw); the
/// session may be truncated. [sessionId] is null when no data reached storage.
final class StopSessionFailed extends StopSessionResult {
  const StopSessionFailed(this.error, this.name, {this.sessionId});

  final Object error;
  final String name;
  final String? sessionId;
}

/// The recording lifecycle: exactly one state at a time, and every operation
/// is refused unless the state matches. [_Stopping] covers finalization's
/// async window so a recording can't be half-latched while another begins.
/// The session payload exists only in [_Recording], so it can't be read or
/// left dangling outside that state.
sealed class _RecordingLifecycle {
  const _RecordingLifecycle();
}

final class _Idle extends _RecordingLifecycle {
  const _Idle();
}

final class _Recording extends _RecordingLifecycle {
  const _Recording({
    required this.writer,
    required this.name,
    required this.startedAt,
  });

  final LiveSessionWriter writer;

  /// Display name, latched at start so [stopSession] can hand it back without
  /// a store lookup.
  final String name;

  /// Recording-start wall clock for the live elapsed readout.
  final DateTime startedAt;
}

/// Finalization's async window; the payload lives in [stopSession]'s local.
final class _Stopping extends _RecordingLifecycle {
  const _Stopping();
}

/// Owns the recording session lifecycle start to finish.
///
/// Dependencies are injected ports: [DataHub] for the data plane,
/// [streamingChanges]/[streamingNow] for liveness, metadata and
/// packet-boundary snapshots, and [SessionStore] for persistence.
/// Link-transition resets live in `StreamResetCoordinator`.
///
/// Failures are reported by audience: [startSession] returns its outcome for a
/// local snackbar; a mid-recording storage failure is emitted as a
/// [RecordingStorageError] on [AppEvents] from [stopSession].
class RecordingController extends ChangeNotifier {
  RecordingController({
    required DataHub dataHub,

    /// Stream liveness source; a recording whose stream dies is auto-stopped.
    /// Same port shape as [FeedHealthTracker].
    required Listenable streamingChanges,
    required bool Function() streamingNow,

    /// The connected device's identity, frozen onto the session at start.
    required Map<String, Object?> Function() deviceMetadataSnapshot,

    /// The raw device KVS, frozen onto the session at start.
    required KvsSnapshot? Function() deviceKvsSnapshot,

    /// Marks a session boundary for packet continuity (the decoder's
    /// `resetContinuity`).
    required void Function() onSessionBoundary,

    required AppEvents events,
  }) : _dataHub = dataHub,
       _streamingChanges = streamingChanges,
       _streamingNow = streamingNow,
       _deviceMetadataSnapshot = deviceMetadataSnapshot,
       _deviceKvsSnapshot = deviceKvsSnapshot,
       _onSessionBoundary = onSessionBoundary,
       _events = events {
    _dataHub.addEventListener(_onHubEvent);
    _streamingChanges.addListener(_onStreamingChanged);
  }

  final DataHub _dataHub;
  final Listenable _streamingChanges;
  final bool Function() _streamingNow;
  final Map<String, Object?> Function() _deviceMetadataSnapshot;
  final KvsSnapshot? Function() _deviceKvsSnapshot;
  final void Function() _onSessionBoundary;
  final AppEvents _events;

  _RecordingLifecycle _lifecycle = const _Idle();

  DateTime? get sessionStartTime => switch (_lifecycle) {
    final _Recording r => r.startedAt,
    _ => null,
  };

  /// True from a committed start until finalization completes, the stopping
  /// window included.
  bool get sessionInProgress => _lifecycle is! _Idle;

  void _set(_RecordingLifecycle next) {
    _lifecycle = next;
    notifyListeners();
  }

  /// Start a recording session: construct the writer and latch it here.
  /// Synchronous end to end (the storage layer does no work until the first
  /// packet creates the directory), so the stream can't change under the
  /// snapshots the writer is built on.
  ///
  /// [name] null auto-names from the wall clock (see [autoSessionName]).
  /// [channelLabels] and [visibleChannels] are persisted for display only.
  /// [displayUnit] is the CSV export's default converted unit. The connected
  /// device's identity is frozen alongside.
  ///
  /// Outcomes are returned, not thrown, so the caller can snackbar them
  /// locally.
  StartSessionResult startSession({
    String? name,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
    required DisplayUnit displayUnit,
  }) {
    assert(_streamingNow());
    if (_lifecycle is! _Idle) return const StartSessionBusy();
    if (_dataHub.taring) return const StartSessionTareInProgress();
    if (deriveFeedHealth(
          streaming: _streamingNow(),
          totalSamples: _dataHub.totalSamples,
          lastDataAt: _dataHub.lastDataAt,
          lastMalformedPacketAt: _dataHub.lastMalformedPacketAt,
          streamStartedAt: _dataHub.streamStartedAt,
        )?.noDataFlowing ??
        false) {
      return const StartSessionNoData();
    }

    // One clock for the auto name, the CSV recordedAt, and the elapsed
    // readout's zero.
    final startedAt = DateTime.now();
    final sessionName = name ?? autoSessionName(startedAt);
    // The journal header is snapshotted here, at recording start.
    final header = (
      name: sessionName,
      sampleRate: _dataHub.sampleRateHz,
      channelCount: kAdcChannelCount,
      channelLabels: List.of(channelLabels),
      tares: List.of(_dataHub.tare),
      calibration: [
        for (int ch = 0; ch < kAdcChannelCount; ch++)
          _dataHub.calibrationFor(ch),
      ],
      visibleChannels: List.of(visibleChannels),
      displayUnit: displayUnit,
      deviceInfo: Map.of(_deviceMetadataSnapshot()),
      deviceKvs: _deviceKvsSnapshot(),
      recordedAt: iso8601WithOffset(startedAt),
    );
    final writer = SessionStore.instance.startSession(
      header,
      sourceRingCapacity: DataHub.maxDataSz,
      // A latched storage failure stops the session the moment it latches, not
      // when a later batch would reveal it.
      onWriteError: (_) => _autoStopOnStorageError(),
    );
    _onSessionBoundary();
    _set(_Recording(writer: writer, name: sessionName, startedAt: startedAt));
    return const StartSessionOk();
  }

  /// Auto-stop on the writer's latched storage failure. Guarded to the
  /// recording state: a failure latching while finalization already drains the
  /// write queue must not start a second stop.
  void _autoStopOnStorageError() {
    if (_lifecycle is _Recording) unawaited(stopSession());
  }

  /// Default session name from the wall clock, e.g. `2026-07-29 14:05:32`.
  /// Zero-padded so derived CSV filenames sort chronologically.
  @visibleForTesting
  static String autoSessionName(DateTime now) {
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final h = now.hour.toString().padLeft(2, '0');
    final min = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    return '${now.year}-$m-$d $h:$min:$s';
  }

  /// Stop the current recording and finalize it. Returns whether the session
  /// was saved, recorded nothing, or failed (see [StopSessionResult]).
  ///
  /// The single place a storage failure is surfaced to the user (as a
  /// [RecordingStorageError] on [AppEvents]).
  Future<StopSessionResult> stopSession() async {
    final current = _lifecycle;
    if (current is! _Recording) {
      return const StopSessionRefused();
    }
    final writer = current.writer;
    final name = current.name;
    _onSessionBoundary();
    _set(const _Stopping());

    // finalizeSession flushes through the writer's serialized queue, draining
    // any in-flight appends first. Its failure is folded into the result, not
    // thrown: stopSession also runs on unawaited auto-stop paths, where a
    // throw would be an unhandled async error.
    Object? error;
    try {
      await SessionStore.instance.finalizeSession(writer: writer);
    } catch (e) {
      error = e;
    }
    if (error != null) {
      _events.emit(RecordingStorageError(error));
    }
    _set(const _Idle());
    final sessionId = writer.sessionId;
    if (error != null) {
      return StopSessionFailed(error, name, sessionId: sessionId);
    }
    return sessionId == null
        ? StopSessionNothingRecorded(name)
        : StopSessionSaved(sessionId, name);
  }

  /// Streams freshly decoded [HubBatchAppended] samples to the writer. A
  /// storage failure surfaces through the writer's onWriteError callback, not
  /// here.
  void _onHubEvent(HubEvent event) => switch (event) {
    final HubBatchAppended batch => _onBatchAppended(batch),
    HubCleared() => null,
  };

  void _onBatchAppended(HubBatchAppended batch) {
    final lifecycle = _lifecycle;
    if (lifecycle is! _Recording) {
      return;
    }
    unawaited(
      lifecycle.writer.appendData(
        _dataHub.snapshotRange(batch.startIdx, batch.count),
      ),
    );
  }

  /// The controller's only link reaction: a recording whose stream dies is
  /// finalized. Stream resets on connection transitions are
  /// `StreamResetCoordinator`'s job.
  void _onStreamingChanged() {
    if (_lifecycle is _Recording && !_streamingNow()) {
      unawaited(stopSession());
    }
  }

  @override
  void dispose() {
    _streamingChanges.removeListener(_onStreamingChanged);
    _dataHub.removeEventListener(_onHubEvent);
    super.dispose();
  }
}
