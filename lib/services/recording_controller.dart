import 'dart:async';

import 'package:flutter/foundation.dart';

import 'adc_packet_decoder.dart';
import 'ble_link_manager.dart';
import 'data_hub.dart';
import 'session_storage.dart';

/// Owns the recording session lifecycle: the [LiveSessionWriter], the
/// in-progress flag the UI keys off, and write-error latching.
///
/// It observes the [DataHub] via [DataHub.onSamplesAppended] to stream exact
/// sample slices to storage, and listens to the [BleLinkManager] so a session
/// is properly finalized (not orphaned) if the link drops mid-recording.
class RecordingController extends ChangeNotifier {
  RecordingController({
    required DataHub dataHub,
    required BleLinkManager linkManager,
    required AdcPacketDecoder decoder,
  })  : _dataHub = dataHub,
        _linkManager = linkManager,
        _decoder = decoder {
    _dataHub.onSamplesAppended = _onSamplesAppended;
    _linkManager.addListener(_onLinkChanged);
  }

  final DataHub _dataHub;
  final BleLinkManager _linkManager;

  /// Needed only to reset packet-continuity tracking at session boundaries so
  /// the first packet of a session isn't diffed against a stale counter.
  final AdcPacketDecoder _decoder;

  bool _sessionInProgress = false;
  bool get sessionInProgress => _sessionInProgress;

  LiveSessionWriter? _sessionWriter;

  /// Set when a recording is auto-stopped because its storage writer started
  /// failing (e.g. disk full / web quota). Consumed and cleared by the UI.
  Object? _sessionWriteError;
  Object? get sessionWriteError => _sessionWriteError;
  void clearSessionWriteError() => _sessionWriteError = null;

  Future<void> startSession(LiveSessionWriter writer) async {
    assert(_linkManager.isStreaming);
    if (_sessionInProgress) return;

    _sessionWriter = writer;
    _sessionWriteError = null;
    _sessionInProgress = true;
    _decoder.resetContinuity();
    notifyListeners();
  }

  /// Stop the current recording and finalize it. Returns the saved session id
  /// (or null if nothing was recording) and any write error the storage writer
  /// latched (non-null means the session may be truncated).
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
        return (sessionId: writer.sessionId, error: error);
      }
    }
    return (sessionId: null, error: null);
  }

  /// Slice of freshly decoded samples, straight from the decoder (via the
  /// hub). Streams it to the writer; if the writer has latched a storage
  /// failure, latch it here and auto-stop instead of recording into a void.
  void _onSamplesAppended(int startIdx, int count) {
    final writer = _sessionWriter;
    if (!_sessionInProgress || writer == null || count <= 0) {
      return;
    }
    if (writer.hasError) {
      _sessionWriteError = writer.writeError;
      unawaited(stopSession());
    } else {
      unawaited(writer.appendData(_dataHub, startIdx, count));
    }
  }

  /// If the link stops streaming while a session is in progress (unexpected
  /// disconnect, failed teardown, …), run the normal stop path so the writer
  /// is flushed and the session finalized instead of being orphaned until the
  /// next app launch's crash recovery.
  void _onLinkChanged() {
    if (_sessionInProgress && !_linkManager.isStreaming) {
      unawaited(_autoStop());
    }
  }

  Future<void> _autoStop() async {
    final result = await stopSession();
    if (result.error != null) {
      // Surface truncation the same way writer-failure auto-stops do.
      _sessionWriteError = result.error;
      notifyListeners();
    }
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
