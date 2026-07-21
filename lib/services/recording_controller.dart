import 'dart:async';

import 'package:flutter/foundation.dart';

import 'adc_packet_decoder.dart';
import 'app_events.dart';
import 'ble_link_manager.dart';
import 'data_hub.dart';
import 'session_storage.dart';

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

/// Refused: a tare is still averaging, and recording now would persist a zero
/// tare. Transient — retry once the tare completes.
final class StartSessionTareInProgress extends StartSessionResult {
  const StartSessionTareInProgress();
}

/// Session creation (the DB row / writer) threw; nothing was latched, so the
/// controller is still idle.
final class StartSessionFailed extends StartSessionResult {
  const StartSessionFailed(this.error);

  final Object error;
}

/// Owns the recording session lifecycle start to finish: creating the session
/// row and [LiveSessionWriter] in [startSession], streaming samples to the
/// writer, and finalizing in [stopSession] — plus the in-progress flag the UI
/// keys off. The UI only toggles and reports outcomes.
///
/// It observes the [DataHub] via [DataHub.addSamplesAppendedListener] to
/// stream exact
/// sample slices to storage, and listens to the [BleLinkManager] for the two
/// link transitions that affect data integrity:
///  * streaming ends — a session in progress is properly finalized (not
///    orphaned) if the link drops mid-recording;
///  * streaming starts — the hub is reset ([DataHub.clear]) and packet
///    continuity is restarted, so the ring buffer, peaks, tare and gaps of a
///    previous connection never splice into the new device's trace (and the
///    new stream's first packet counter is never diffed against the previous
///    device's, which would inject a spurious gap).
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
    required BleLinkManager linkManager,
    required AdcPacketDecoder decoder,
    required AppEvents events,
  }) : _dataHub = dataHub,
       _linkManager = linkManager,
       _decoder = decoder,
       _events = events {
    _dataHub.addSamplesAppendedListener(_onSamplesAppended);
    _linkManager.addListener(_onLinkChanged);
  }

  final DataHub _dataHub;
  final BleLinkManager _linkManager;
  final AppEvents _events;

  /// Needed to reset packet-continuity tracking at stream/session boundaries
  /// so the first packet after a boundary isn't diffed against a stale counter.
  final AdcPacketDecoder _decoder;

  bool _sessionInProgress = false;
  bool get sessionInProgress => _sessionInProgress;

  /// Link state at the previous [_onLinkChanged] notification; used to detect
  /// the not-streaming -> streaming edge (a new device stream starting).
  bool _wasStreaming = false;

  LiveSessionWriter? _sessionWriter;

  /// Display name of the in-progress session, latched by [startSession] so
  /// [stopSession] can hand it back to the UI without a DB lookup.
  String? _sessionName;

  /// Start a new recording session: create the session row and its writer
  /// (via [SessionStorage.startSession]) and latch them here.
  ///
  /// [name] is the session's display name; null auto-names it from the wall
  /// clock (e.g. `7/20 14:05`). [channelLabels] and [visibleChannels] are
  /// persisted for display only (see [SessionStorage.startSession]).
  ///
  /// Outcomes are returned, not thrown, so the caller (the live tab's record
  /// button) can snackbar them locally; null means a session was already in
  /// progress (a no-op the UI prevents by toggling on [sessionInProgress]).
  Future<StartSessionResult?> startSession({
    String? name,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
  }) async {
    assert(_linkManager.isStreaming);
    if (_sessionInProgress) return null;
    // A tare is still averaging; recording now would persist a zero tare.
    if (_dataHub.taring) return const StartSessionTareInProgress();

    final sessionName = name ?? _autoSessionName(DateTime.now());
    final LiveSessionWriter writer;
    try {
      writer = await SessionStorage.startSession(
        dataHub: _dataHub,
        name: sessionName,
        channelLabels: channelLabels,
        visibleChannels: visibleChannels,
      );
    } catch (e) {
      return StartSessionFailed(e);
    }

    _sessionWriter = writer;
    _sessionName = sessionName;
    _sessionInProgress = true;
    _decoder.resetContinuity();
    notifyListeners();
    return const StartSessionOk();
  }

  /// Default session name from the wall clock, e.g. `7/20 14:05`.
  static String _autoSessionName(DateTime now) =>
      '${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}';

  /// Stop the current recording and finalize it. Returns the saved session id
  /// and name (or nulls if nothing was recording) and any write error the
  /// storage writer latched (non-null means the session may be truncated).
  ///
  /// This is the single place a storage failure is surfaced to the user (as a
  /// [RecordingStorageError] on [AppEvents]); callers only use the returned
  /// error to branch (e.g. suppress the "Session saved" notice).
  Future<({int? sessionId, String? name, Object? error})> stopSession() async {
    if (_sessionInProgress) {
      _sessionInProgress = false;
      final writer = _sessionWriter;
      final name = _sessionName;
      _sessionWriter = null;
      _sessionName = null;
      _decoder.resetContinuity();
      notifyListeners();

      if (writer != null) {
        // finalizeSession flushes through the writer's serialized queue, which
        // drains any in-flight (unawaited) appends first.
        final error = await SessionStorage.finalizeSession(writer: writer);
        if (error != null) {
          _events.emit(RecordingStorageError(error));
        }
        return (sessionId: writer.sessionId, name: name, error: error);
      }
    }
    return (sessionId: null, name: null, error: null);
  }

  /// Slice of freshly decoded samples, straight from the decoder (via the
  /// hub). Streams it to the writer; if the writer has latched a storage
  /// failure, auto-stop instead of recording into a void ([stopSession]'s
  /// finalization re-detects the latched error and surfaces it).
  void _onSamplesAppended(int startIdx, int count) {
    final writer = _sessionWriter;
    if (!_sessionInProgress || writer == null) {
      return;
    }
    if (writer.hasError) {
      unawaited(stopSession());
    } else {
      unawaited(writer.appendData(_dataHub, startIdx, count));
    }
  }

  /// React to the two link transitions that affect data integrity (see the
  /// class doc): a dropped link finalizes any in-progress session; a freshly
  /// started stream resets the hub and packet continuity.
  void _onLinkChanged() {
    final bool streaming = _linkManager.isStreaming;
    if (_sessionInProgress && !streaming) {
      unawaited(stopSession());
    }
    if (streaming && !_wasStreaming) {
      // New device stream. Clear the previous stream's ring buffer, peaks,
      // tare and gaps so two connections never splice into one trace, and
      // restart continuity so the new stream's first packet isn't diffed
      // against the old stream's counter. Runs on stream entry (not on
      // disconnect) so a recording being finalized after an unexpected drop
      // can still read the old ring data while it flushes.
      _dataHub.clear();
      _decoder.resetContinuity();
    }
    _wasStreaming = streaming;
  }

  @override
  void dispose() {
    _linkManager.removeListener(_onLinkChanged);
    _dataHub.removeSamplesAppendedListener(_onSamplesAppended);
    super.dispose();
  }
}
