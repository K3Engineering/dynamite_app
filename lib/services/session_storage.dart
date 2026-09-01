import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';
import '../models/device_profile.dart';
import '../models/display_unit.dart';
import '../utils/format.dart';
import 'live_session_writer.dart';
import 'session_persistence.dart';
import 'session_store.dart';

/// The recording-side face of the session store: writer construction at
/// start, finalize-or-abort at stop. Reads/edits/listings/loads flow through
/// session_queries.dart instead — this class only owns the recording
/// lifecycle.
class SessionStorage {
  /// Start a new streaming session. The returned [LiveSessionWriter] is fed
  /// sample slices via [LiveSessionWriter.appendData] as data arrives and is
  /// passed to [finalizeSession] when recording stops. Pure construction —
  /// the session directory is only created by the writer's first packet, so
  /// starting can never fail and never leaves an artifact behind without
  /// data.
  ///
  /// Note: every session stores all [kAdcChannelCount]; [channelLabels]
  /// and [visibleChannels] are retained for display only. [deviceMetadata] is
  /// the connected device's identity (see [toSessionDeviceMetadata]), frozen
  /// for export. [boardMeta] is the board-level calibration provenance; null
  /// when no board data resolved.
  ///
  /// This is hub-agnostic by contract: the caller snapshots everything the
  /// live buffer would supply ([tare], [channelCalibration],
  /// [samplesPerSec], [sourceRingCapacity]), so the storage layer never
  /// imports the hub.
  static LiveSessionWriter startSession({
    required List<double?> tare,
    required List<ChannelCalibration> channelCalibration,
    required int samplesPerSec,
    required int sourceRingCapacity,
    required String name,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
    required DisplayUnit displayUnit,
    required Map<String, Object?> deviceMetadata,
    required SessionBoardMeta? boardMeta,
  }) {
    return LiveSessionWriter(
      (
        name: name,
        sampleRate: samplesPerSec,
        // We always persist every ADC channel, so the journal's channel
        // count must match what the writer packs (and what loadSession reads
        // back).
        channelCount: kAdcChannelCount,
        channelLabels: List.of(channelLabels),
        // Snapshots: playback converts through these, so a later re-tare or
        // recalibration can never rewrite history. Null tares (never tared)
        // are a first-class value, not a floored number.
        tares: List.of(tare),
        calibration: List.of(channelCalibration),
        visibleChannels: List.of(visibleChannels),
        // Frozen as the CSV export's default converted unit (the CSV
        // format's recording-time snapshot requirement).
        displayUnit: displayUnit.name,
        deviceInfo: Map.of(deviceMetadata),
        boardMeta: boardMeta,
        // Frozen at recording start, NOT at directory creation (which is
        // the first packet's write, later): the wall clock the CSV's
        // recorded_at asserts.
        recordedAt: iso8601WithOffset(DateTime.now()),
      ),
      sourceRingCapacity: sourceRingCapacity,
      sinkFactory: (meta, firstData) => SessionStore.instance.createDataSink(
        meta: meta,
        firstData: firstData,
      ),
    );
  }

  /// Finalize a streaming session: drain the write queue, release the sink,
  /// verify the persisted length against the accepted-frames claim, and
  /// write the completion marker — ONLY when every step above came back
  /// clean. The marker is the catalog's entire complete-verdict, so a
  /// finalize that latched any failure (a mid-recording write error, a
  /// sink-close failure, or a count mismatch) must not write it: the
  /// session lists as interrupted instead, salvageable forever — never
  /// listed as a recording the store cannot vouch for.
  ///
  /// If no data ever reached storage, the directory was never created and
  /// there is nothing to finalize (recording nothing saves nothing).
  ///
  /// Returns the writer's latched write error, a sink-close failure, or a
  /// verification error (if any); when non-null, the caller should surface
  /// it. Releasing the sink folds into the return value instead of throwing.
  static Future<Object?> finalizeSession({
    required LiveSessionWriter writer,
  }) async {
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
      final acked = writer.ackedDataLength ?? 0;
      final expected = writer.expectedDataBytes;
      if (acked != expected) {
        error ??= StateError(
          'Session $sessionId: persisted $acked bytes but counted $expected '
          '— the storage layer dropped samples',
        );
      }
      if (error == null) {
        await SessionStore.instance.touchFinal(sessionId);
      } else {
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
  LiveSessionWriter startSession({
    required List<double?> tare,
    required List<ChannelCalibration> channelCalibration,
    required int samplesPerSec,
    required int sourceRingCapacity,
    required String name,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
    required DisplayUnit displayUnit,
    required Map<String, Object?> deviceMetadata,
    required SessionBoardMeta? boardMeta,
  }) => SessionStorage.startSession(
    tare: tare,
    channelCalibration: channelCalibration,
    samplesPerSec: samplesPerSec,
    sourceRingCapacity: sourceRingCapacity,
    name: name,
    channelLabels: channelLabels,
    visibleChannels: visibleChannels,
    displayUnit: displayUnit,
    deviceMetadata: deviceMetadata,
    boardMeta: boardMeta,
  );

  @override
  Future<Object?> finalizeSession({required LiveSessionWriter writer}) =>
      SessionStorage.finalizeSession(writer: writer);
}
