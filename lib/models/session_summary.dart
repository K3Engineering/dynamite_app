/// One session as the UI sees it — immutable, detached from the store's
/// file layout. Built by the session store (the screens' only read path is
/// session_queries.dart); the screens never see journal bytes.
library;

class SessionSummary {
  SessionSummary({
    required this.id,
    required this.name,
    required this.notes,
    required this.createdAt,
    required this.durationMs,
    required this.channelCount,
    required this.sampleRate,
    required this.displayUnit,
    required this.deviceInfoJson,
    required this.recordedAt,
    required List<String> channelLabels,
    required List<bool> visibleChannels,
  }) : channelLabels = List.unmodifiable(channelLabels),
       visibleChannels = List.unmodifiable(visibleChannels);

  /// The session id — the session directory's name.
  final String id;
  final String name;
  final String notes;

  /// The local wall-clock instant the session was created, decoded from
  /// the id (the id IS the timestamp, so the two can never disagree).
  final DateTime createdAt;

  /// Derived from data.raw's frame count and the journal's sample rate —
  /// never stored, so it can never disagree with the data.
  final int durationMs;
  final int channelCount;
  final int sampleRate;

  /// The unit frozen at recording start (a `DisplayUnit.name`).
  final String displayUnit;

  /// The frozen `device` metadata block, as JSON (see
  /// `toSessionDeviceMetadata` in session_metadata.dart).
  final String deviceInfoJson;

  /// The frozen dynamite-csv `recorded_at` string (local wall clock with
  /// zone offset) — the export's human timestamp. [createdAt] is the
  /// sort/display instant; this is the artifact field.
  final String recordedAt;

  /// Per-channel titles from recording start.
  final List<String> channelLabels;

  /// Per-channel graph/stat visibility, exactly [channelCount] entries;
  /// the recording-time default plus any post-recording edits.
  final List<bool> visibleChannels;
}
