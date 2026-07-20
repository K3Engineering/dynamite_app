import 'dart:async';

import 'package:flutter/foundation.dart';

import 'adc_packet_decoder.dart';
import 'app_events.dart';
import 'ble_link_manager.dart';
import 'data_hub.dart';
import 'session_storage.dart';

/// Owns the recording session lifecycle: the [LiveSessionWriter] and the
/// in-progress flag the UI keys off.
///
/// It observes the [DataHub] via [DataHub.onSamplesAppended] to stream exact
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
/// Storage failures are surfaced as a [RecordingStorageError] on [AppEvents]
/// (emitted from [stopSession], the single finalization path).
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
    _dataHub.onSamplesAppended = _onSamplesAppended;
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

  Future<void> startSession(LiveSessionWriter writer) async {
    assert(_linkManager.isStreaming);
    if (_sessionInProgress) return;

    _sessionWriter = writer;
    _sessionInProgress = true;
    _decoder.resetContinuity();
    notifyListeners();
  }

  /// Stop the current recording and finalize it. Returns the saved session id
  /// (or null if nothing was recording) and any write error the storage writer
  /// latched (non-null means the session may be truncated).
  ///
  /// This is the single place a storage failure is surfaced to the user (as a
  /// [RecordingStorageError] on [AppEvents]); callers only use the returned
  /// error to branch (e.g. suppress the "Session saved" notice).
  Future<({int? sessionId, Object? error})> stopSession() async {
    if (_sessionInProgress) {
      _sessionInProgress = false;
      final writer = _sessionWriter;
      _sessionWriter = null;
      _decoder.resetContinuity();
      notifyListeners();

      if (writer != null) {
        // finalizeSession flushes through the writer's serialized queue, which
        // drains any in-flight (unawaited) appends first.
        final error = await SessionStorage.finalizeSession(writer: writer);
        if (error != null) {
          _events.emit(RecordingStorageError(error));
        }
        return (sessionId: writer.sessionId, error: error);
      }
    }
    return (sessionId: null, error: null);
  }

  /// Slice of freshly decoded samples, straight from the decoder (via the
  /// hub). Streams it to the writer; if the writer has latched a storage
  /// failure, auto-stop instead of recording into a void ([stopSession]'s
  /// finalization re-detects the latched error and surfaces it).
  void _onSamplesAppended(int startIdx, int count) {
    final writer = _sessionWriter;
    if (!_sessionInProgress || writer == null || count <= 0) {
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
    if (_dataHub.onSamplesAppended == _onSamplesAppended) {
      _dataHub.onSamplesAppended = null;
    }
    super.dispose();
  }
}
