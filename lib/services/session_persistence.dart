import 'dart:typed_data';

import '../models/channel_calibration.dart';
import '../models/display_unit.dart';
import 'live_session_writer.dart';

/// Recording's port onto session persistence: exactly the three lifecycle
/// operations a recording needs. The consumer defines the contract (the same
/// move as `AdcSink` for the decoder), so `RecordingController` never imports
/// the storage layer's statics; `StaticSessionPersistence` in
/// session_storage.dart adapts the real implementation and tests can double
/// it without opening a database.
abstract interface class SessionPersistence {
  /// Create the session row and its writer. Everything the live buffer would
  /// supply ([tare], [channelCalibration], [samplesPerSec],
  /// [sourceRingCapacity]) is snapshotted by the caller, so the storage side
  /// never consults live state.
  Future<LiveSessionWriter> startSession({
    required Float64List tare,
    required List<ChannelCalibration> channelCalibration,
    required int samplesPerSec,
    required int sourceRingCapacity,
    required String name,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
    required DisplayUnit displayUnit,
    required Map<String, Object?> deviceMetadata,
  });

  /// Delete a session row created by [startSession] but never latched (the
  /// stream changed while the row was being inserted). The writer has
  /// written no chunks, so this is a plain row delete, not a recovery case.
  Future<void> discardSession(LiveSessionWriter writer);

  /// Flush any buffered samples, then record the aggregates the writer
  /// accumulated and mark the session completed. Returns the writer's
  /// latched write error (if any); non-null means the session may be
  /// truncated and the caller should surface it.
  Future<Object?> finalizeSession({required LiveSessionWriter writer});
}
