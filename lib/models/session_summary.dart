/// One session row as the UI sees it — immutable and drift-free. Built by
/// session_queries.dart (the screens' only DB read path); the screens never
/// see the drift row type.
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
    required List<String> channelLabels,
    required List<bool> visibleChannels,
  }) : channelLabels = List.unmodifiable(channelLabels),
       visibleChannels = List.unmodifiable(visibleChannels);

  final int id;
  final String name;
  final String notes;
  final DateTime createdAt;
  final int durationMs;
  final int channelCount;
  final int sampleRate;

  /// The unit frozen at recording start (a `DisplayUnit.name`).
  final String displayUnit;

  /// The frozen `device` metadata block, as stored JSON (see
  /// `toSessionDeviceMetadata` in session_storage.dart).
  final String deviceInfoJson;

  /// Per-channel titles; 'Ch n' where the stored column had nothing
  /// usable for that index.
  final List<String> channelLabels;

  /// Per-channel graph/stat visibility, exactly [channelCount] entries;
  /// true where the stored column had nothing usable for that index.
  final List<bool> visibleChannels;
}
