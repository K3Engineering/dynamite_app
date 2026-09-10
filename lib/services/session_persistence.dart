import 'live_session_writer.dart';

/// Recording's port onto session persistence: exactly the two lifecycle
/// operations a recording needs. The consumer defines the contract (the same
/// move as `AdcSink` for the decoder), so `RecordingController` never imports
/// the storage layer's statics; `StaticSessionPersistence` in
/// session_storage.dart adapts the real implementation and tests can double
/// it without opening the store.
abstract interface class SessionPersistence {
  /// Construct the session's writer from the caller-snapshotted [header]
  /// (every journal-line-1 field, frozen at recording start — the storage
  /// side never consults live state). Pure construction: no store work
  /// happens until the writer's first packet creates the session directory,
  /// so this can never fail and never needs discarding. [onWriteError] is the
  /// writer's latched-error callback (see LiveSessionWriter.onWriteError).
  LiveSessionWriter startSession(
    SessionHeader header, {
    required int sourceRingCapacity,
    required void Function(Object error) onWriteError,
  });

  /// Drain the write queue, verify the persisted length against the
  /// accepted-frames claim, and mark the session completed. Returns the
  /// writer's latched write error (if any); non-null means the session may
  /// be truncated and the caller should surface it. A session that received
  /// no data never got a directory, so there is nothing to finalize.
  Future<Object?> finalizeSession({required LiveSessionWriter writer});
}
