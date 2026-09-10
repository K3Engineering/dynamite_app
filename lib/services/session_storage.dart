import 'live_session_writer.dart';
import 'session_persistence.dart';
import 'session_store.dart';

/// The recording-side face of the session store: writer construction at
/// start, finalize-or-abort at stop. Reads/edits/listings/loads flow through
/// session_queries.dart instead — this class only owns the recording
/// lifecycle.
class SessionStorage {
  /// Start a new streaming session from the caller-snapshotted [header]
  /// (every journal-line-1 field, including the recording-start clock). The
  /// returned [LiveSessionWriter] is fed sample slices via
  /// [LiveSessionWriter.appendData] as data arrives and is passed to
  /// [finalizeSession] when recording stops. Pure construction — the session
  /// directory is only created by the writer's first packet, so starting can
  /// never fail and never leaves an artifact behind without data.
  ///
  /// This is hub-agnostic by contract: the caller snapshots everything the
  /// live buffer would supply, so the storage layer never imports the hub.
  static LiveSessionWriter startSession(
    SessionHeader header, {
    required int sourceRingCapacity,
    required void Function(Object error) onWriteError,
  }) {
    return LiveSessionWriter(
      header,
      sourceRingCapacity: sourceRingCapacity,
      onWriteError: onWriteError,
      sinkFactory: (meta, firstData) => SessionStore.instance.createDataSink(
        meta: meta,
        firstData: firstData,
      ),
    );
  }

  /// Finalize a streaming session: drain the write queue, release the sink,
  /// verify the persisted length against the accepted-frames claim, and —
  /// ONLY when every step above came back clean — write the completion
  /// marker (see SessionFilesBackend for the marker's write discipline). A
  /// latched failure (a mid-recording write error, a sink-close failure, or
  /// a count mismatch) leaves no marker: the session lists as interrupted.
  ///
  /// If no data ever reached storage, the directory was never created and
  /// there is nothing to finalize (recording nothing saves nothing).
  ///
  /// Returns the writer's latched write error, a sink-close failure, a
  /// verification error, or a completion-marker write failure (if any);
  /// when non-null, the caller should surface it. Releasing the sink and
  /// writing the marker fold into the return value instead of throwing.
  static Future<Object?> finalizeSession({
    required LiveSessionWriter writer,
  }) async {
    // TODO(known-issue): dart:io file ops have no timeout — a wedged
    // flush() (an ailing disk) hangs finalize, and stopSession with it,
    // forever. Web is covered by SinkWorkerTransport's per-request timeout.
    await writer.flush();
    final sessionId = writer.sessionId;
    Object? error = writer.writeError;
    try {
      await writer.closeSink();
    } catch (e) {
      error ??= e;
    }
    if (sessionId != null) {
      // Fail loud on an accepted-vs-persisted mismatch: the writer counted
      // every accepted packet's frames, so data.raw must hold exactly that
      // many bytes after the last ack. A silent drop anywhere between
      // accepted slice and flushed file would otherwise leave the session
      // claiming samples that were never written.
      // Non-null by construction: sessionId and the acked length latch
      // together on the first packet (see LiveSessionWriter).
      final acked = writer.ackedDataLength!;
      final expected = writer.expectedDataBytes;
      if (acked != expected) {
        error ??= StateError(
          'Session $sessionId: persisted $acked bytes but counted $expected '
          '— the storage layer dropped samples',
        );
      }
      if (error == null) {
        try {
          await SessionStore.instance.touchFinal(sessionId);
        } catch (e) {
          // A marker write that failed leaves no marker, so the dir is by
          // definition an interrupted session: fall through to the abort
          // path, which splices that verdict into the catalog NOW. Without
          // this the recording would stay invisible until the next
          // startup's scan — hidden from exactly the user who saw the stop
          // error and would salvage it.
          error = e;
        }
      }
      if (error != null) {
        await SessionStore.instance.abortSession(sessionId);
      }
    }
    return error;
  }
}

/// Adapts the [SessionStorage] statics to the [SessionPersistence] port
/// `RecordingController` consumes (main wires this in; recording tests
/// point the store singleton at a temp root instead).
class StaticSessionPersistence implements SessionPersistence {
  const StaticSessionPersistence();

  @override
  LiveSessionWriter startSession(
    SessionHeader header, {
    required int sourceRingCapacity,
    required void Function(Object error) onWriteError,
  }) => SessionStorage.startSession(
    header,
    sourceRingCapacity: sourceRingCapacity,
    onWriteError: onWriteError,
  );

  @override
  Future<Object?> finalizeSession({required LiveSessionWriter writer}) =>
      SessionStorage.finalizeSession(writer: writer);
}
