import '../models/board_calibration.dart';
import '../models/channel_calibration.dart';
import '../models/display_unit.dart';
import 'live_session_writer.dart';

/// Recording's port onto session persistence: exactly the two lifecycle
/// operations a recording needs. The consumer defines the contract (the same
/// move as `AdcSink` for the decoder), so `RecordingController` never imports
/// the storage layer's statics; `StaticSessionPersistence` in
/// session_storage.dart adapts the real implementation and tests can double
/// it without opening a database.
abstract interface class SessionPersistence {
  /// Construct the session's writer. Everything the live buffer would
  /// supply ([tare], [channelCalibration], [samplesPerSec],
  /// [sourceRingCapacity]) is snapshotted by the caller, so the storage side
  /// never consults live state. Pure construction: no store work happens
  /// until the writer's first packet creates the session directory, so this
  /// can never fail and never needs discarding.
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
  });

  /// Drain the write queue, verify the persisted length against the
  /// accepted-frames claim, and mark the session completed. Returns the
  /// writer's latched write error (if any); non-null means the session may
  /// be truncated and the caller should surface it. A session that received
  /// no data never got a directory, so there is nothing to finalize.
  Future<Object?> finalizeSession({required LiveSessionWriter writer});
}
