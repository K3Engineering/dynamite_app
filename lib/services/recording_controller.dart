import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_events.dart';
import 'data_hub.dart';
import 'live_session_writer.dart';
import 'session_persistence.dart';
import '../models/board_calibration.dart';
import '../models/device_profile.dart';
import '../models/display_unit.dart';
import '../models/feed_health.dart';

/// Outcome of [RecordingController.startSession]. The outcomes are mutually
/// exclusive, so they form a sealed type the caller switches exhaustively —
/// unlike [RecordingController.stopSession]'s result, whose fields are
/// independent of each other (a record).
sealed class StartSessionResult {
  const StartSessionResult();
}

/// The session is recording.
final class StartSessionOk extends StartSessionResult {
  const StartSessionOk();
}

/// Refused: another lifecycle operation is already in flight (a session is
/// recording, or a stop is finalizing) — one outstanding operation at a time.
/// The UI prevents this by toggling on [RecordingController.sessionInProgress];
/// reaching it means a second tap landed inside the previous operation's
/// async window.
final class StartSessionBusy extends StartSessionResult {
  const StartSessionBusy();
}

/// Refused: a tare is still averaging, so recording now would freeze the
/// pre-tare offsets (re-taring is refused for the session's lifetime).
/// Transient — retry once the tare completes.
final class StartSessionTareInProgress extends StartSessionResult {
  const StartSessionTareInProgress();
}

/// Refused: the link is streaming but no decodable data is flowing — the
/// feed is silent, delivers only malformed packets, or has stalled (see
/// [deriveFeedHealth]) — so the session would record nothing. Transient —
/// retry once data flows.
final class StartSessionNoData extends StartSessionResult {
  const StartSessionNoData();
}

/// The recording lifecycle, serialized: exactly one of these at a time, and
/// every operation is refused unless the state matches. [stopping] covers
/// the finalization's async window, so a recording can never be half-latched
/// while another begins. (Starting has no async window: the storage layer
/// does no DB work until data exists, so latching is synchronous.)
enum _RecordingState { idle, recording, stopping }

/// Owns the recording session lifecycle start to finish; the UI only
/// toggles and reports outcomes.
///
/// The lifecycle is the [_RecordingState] machine above: [startSession] may
/// run only from idle, [stopSession] only from recording, and the async gaps
/// in each are covered states rather than windows where the controller
/// merely "looks" idle.
///
/// Dependencies are ports, not subsystems: the live store is [DataHub] (the
/// data plane — starting a session snapshots tare, calibration and sample
/// rate off it, more than the [FeedHealthSource] read port covers), stream
/// liveness arrives through the [streamingChanges]/[streamingNow]
/// port, and device metadata, packet-boundary resets and persistence are
/// injected ([deviceMetadataSnapshot], [onSessionBoundary], [persistence]).
/// The link-transition resets this controller used to own (hub clear on
/// stream entry, calibration forget on drop) live in
/// `StreamResetCoordinator`.
///
/// Failures are reported two ways, by audience: [startSession] refuses or
/// fails in response to the user who just tapped record, so its outcomes are
/// returned for a local snackbar; a storage failure latching mid-recording is
/// surfaced as a [RecordingStorageError] on [AppEvents] (emitted from
/// [stopSession], the single finalization path), since the tab that started
/// the session may no longer be mounted.
class RecordingController extends ChangeNotifier {
  RecordingController({
    required DataHub dataHub,

    /// Stream liveness, as a notify source plus a poll closure (the same
    /// port shape [FeedHealthTracker] uses); main wires the link manager
    /// in. The controller's only link reaction is auto-stop: a recording
    /// whose stream dies is finalized.
    required Listenable streamingChanges,
    required bool Function() streamingNow,

    /// Snapshot of the connected device's identity (the CSV `device` block
    /// — csv-format-v1.md), frozen onto the session row at start.
    required Map<String, Object?> Function() deviceMetadataSnapshot,

    /// Marks a session boundary for packet continuity: the first packet of
    /// a session must not be diffed against a stale counter from across the
    /// boundary (the decoder's `resetContinuity`, wired in main).
    required void Function() onSessionBoundary,

    /// The session persistence port (see [SessionPersistence]).
    required SessionPersistence persistence,
    required AppEvents events,
  }) : _dataHub = dataHub,
       _streamingChanges = streamingChanges,
       _streamingNow = streamingNow,
       _deviceMetadataSnapshot = deviceMetadataSnapshot,
       _onSessionBoundary = onSessionBoundary,
       _persistence = persistence,
       _events = events {
    _dataHub.addSamplesAppendedListener(_onSamplesAppended);
    _streamingChanges.addListener(_onStreamingChanged);
  }

  final DataHub _dataHub;
  final Listenable _streamingChanges;
  final bool Function() _streamingNow;
  final Map<String, Object?> Function() _deviceMetadataSnapshot;
  final void Function() _onSessionBoundary;
  final SessionPersistence _persistence;
  final AppEvents _events;

  _RecordingState _state = _RecordingState.idle;

  LiveSessionWriter? _sessionWriter;

  /// Display name of the in-progress session, latched by [startSession] so
  /// [stopSession] can hand it back to the UI without a DB lookup.
  String? _sessionName;

  /// True from the moment a start is committed until finalization completes
  /// — the stopping window included, so the UI's record toggle never sees a
  /// fake idle gap. Derived from the state machine, so it can never
  /// disagree with the lifecycle it describes.
  bool get sessionInProgress => _state != _RecordingState.idle;

  /// Every transition notifies: [sessionInProgress] covers the stopping
  /// window, not just the latched recording.
  void _transitionTo(_RecordingState next) {
    _state = next;
    notifyListeners();
  }

  /// Start a new recording session: construct the writer (via the
  /// persistence port) and latch it here. Synchronous end to end — the
  /// storage layer does no DB work until the first chunk flush creates the
  /// session row — so there is no async window in which the stream could
  /// change out from under the snapshots the writer is built on, and no
  /// discarded row to clean up if it did.
  ///
  /// [name] is the session's display name; null auto-names it from the wall
  /// clock (e.g. `2026-07-29 14:05:32` — see [autoSessionName]).
  /// [channelLabels] and [visibleChannels] are persisted for display only
  /// (see [SessionPersistence.startSession]). [displayUnit] is frozen onto
  /// the session row as the CSV export's default converted unit. The connected
  /// device's identity is frozen alongside (the CSV `device` block).
  ///
  /// Outcomes are returned, not thrown, so the caller (the live tab's record
  /// button) can snackbar them locally.
  StartSessionResult startSession({
    String? name,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
    required DisplayUnit displayUnit,
  }) {
    assert(_streamingNow());
    if (_state != _RecordingState.idle) return const StartSessionBusy();
    // A tare is still averaging; recording now would freeze the pre-tare
    // offsets for the session's lifetime.
    if (_dataHub.taring) return const StartSessionTareInProgress();
    // Refuse to latch an empty session onto a feed that delivers nothing
    // decodable (a stream that never produced data, produces only malformed
    // packets, or has gone silent).
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

    final sessionName = name ?? autoSessionName(DateTime.now());
    _sessionWriter = _persistence.startSession(
      tare: _dataHub.tare,
      // Snapshot the per-channel calibration in effect now; playback
      // converts through it even if calibration changes later.
      channelCalibration: [
        for (int ch = 0; ch < kAdcChannelCount; ch++)
          _dataHub.calibrationFor(ch),
      ],
      samplesPerSec: _dataHub.sampleRateHz,
      sourceRingCapacity: DataHub.maxDataSz,
      name: sessionName,
      channelLabels: channelLabels,
      visibleChannels: visibleChannels,
      displayUnit: displayUnit,
      deviceMetadata: _deviceMetadataSnapshot(),
      // Freeze the board-level calibration provenance alongside the
      // per-channel snapshot above; null when no board data resolved.
      boardMeta: switch (_dataHub.boardCalibration) {
        final board? => SessionBoardMeta.fromBoard(board),
        null => null,
      },
    );
    _sessionName = sessionName;
    _onSessionBoundary();
    _transitionTo(_RecordingState.recording);
    return const StartSessionOk();
  }

  /// Default session name from the wall clock, e.g. `2026-07-29 14:05:32` —
  /// the same ISO Y-M-D voice as [formatDate] (utils/format.dart), 24h and
  /// zero-padded. Seconds included so two sessions started within the same
  /// minute don't collide, and the zero-padding keeps the derived CSV
  /// filename (`2026-07-29 14-05-32.csv`) sorting chronologically in a file
  /// browser.
  @visibleForTesting
  static String autoSessionName(DateTime now) {
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final h = now.hour.toString().padLeft(2, '0');
    final min = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    return '${now.year}-$m-$d $h:$min:$s';
  }

  /// Stop the current recording and finalize it. Returns the saved session id
  /// and name (or nulls when called outside the recording state — the state
  /// machine refuses the no-op) and any write error the storage writer
  /// latched (non-null means the session may be truncated). The id is also
  /// null when the session recorded nothing: with no first chunk there was
  /// never a row, so "recorded nothing" saves nothing.
  ///
  /// This is the single place a storage failure is surfaced to the user (as a
  /// [RecordingStorageError] on [AppEvents]); callers only use the returned
  /// error to branch (e.g. suppress the "Session saved" notice).
  Future<({int? sessionId, String? name, Object? error})> stopSession() async {
    if (_state != _RecordingState.recording) {
      return (sessionId: null, name: null, error: null);
    }
    final writer = _sessionWriter!;
    final name = _sessionName;
    _sessionWriter = null;
    _sessionName = null;
    _onSessionBoundary();
    _transitionTo(_RecordingState.stopping);

    // finalizeSession flushes through the writer's serialized queue, which
    // drains any in-flight (unawaited) appends first. A failure there (e.g.
    // the DB itself is gone) is folded into the returned error rather than
    // thrown: stopSession also runs on unawaited auto-stop paths (link
    // drop, writer error), where a throw would be an unhandled async error.
    Object? error;
    try {
      error = await _persistence.finalizeSession(writer: writer);
    } catch (e) {
      error = e;
    }
    if (error != null) {
      _events.emit(RecordingStorageError(error));
    }
    _transitionTo(_RecordingState.idle);
    return (sessionId: writer.sessionId, name: name, error: error);
  }

  /// Slice of freshly decoded samples, straight from the decoder (via the
  /// hub). Streams it to the writer; if the writer has latched a storage
  /// failure, auto-stop instead of recording into a void ([stopSession]'s
  /// finalization re-detects the latched error and surfaces it).
  void _onSamplesAppended(int startIdx, int count) {
    final writer = _sessionWriter;
    if (writer == null) {
      return;
    }
    if (writer.hasError) {
      unawaited(stopSession());
    } else {
      unawaited(writer.appendData(_dataHub.snapshotRange(startIdx, count)));
    }
  }

  /// The controller's only link reaction: a recording whose stream dies is
  /// finalized. (A start in flight aborts itself via [startSession]'s
  /// post-await checks; a finalization in flight reads only snapshots it
  /// already took.) Stream resets on connection transitions are
  /// `StreamResetCoordinator`'s job.
  void _onStreamingChanged() {
    if (_state == _RecordingState.recording && !_streamingNow()) {
      unawaited(stopSession());
    }
  }

  @override
  void dispose() {
    _streamingChanges.removeListener(_onStreamingChanged);
    _dataHub.removeSamplesAppendedListener(_onSamplesAppended);
    super.dispose();
  }
}
