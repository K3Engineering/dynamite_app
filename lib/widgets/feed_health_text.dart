import '../services/feed_health.dart';
import '../utils/format.dart';

/// User-facing presentation for feed health: the status-bar label and the
/// detail dialog body. Kept out of the service layer: the enum and
/// classification live in `feed_health.dart`; the copy lives here.
extension FeedHealthPresentation on FeedHealth {
  /// Nothing decodable is arriving right now: the live UI grays its readings
  /// and the rate label reads "no data".
  bool get noDataFlowing =>
      this == FeedHealth.stopped ||
      this == FeedHealth.blocked ||
      this == FeedHealth.silent;

  /// Worth surfacing to the user (a label, and details on tap). [starting]
  /// and [flowing] present as normal instead.
  bool get worthReporting =>
      this != FeedHealth.starting && this != FeedHealth.flowing;

  /// One-line label for the status bar and the Devices row. Null for states
  /// with nothing to report.
  String? get shortLabel => switch (this) {
    FeedHealth.degraded => 'Some packets malformed',
    FeedHealth.stopped => 'Stream stopped',
    FeedHealth.blocked => 'Packets malformed — no decodable data',
    FeedHealth.silent => 'No data from device',
    _ => null,
  };

  /// Detail body for the tap dialog, with the raw numbers when known.
  String detail({int? malformedLen, DateTime? lastDataAt}) => switch (this) {
    FeedHealth.degraded =>
      'Some packets arrived undecodable'
          '${malformedLen != null ? ' (last: $malformedLen bytes)' : ''}. '
          'The stream is otherwise flowing.',
    FeedHealth.stopped =>
      'Data was flowing, then stopped.'
          '${lastDataAt != null ? ' Last data received at ${formatTimestamp(lastDataAt)}.' : ''}',
    FeedHealth.blocked =>
      'Packets are arriving, but none can be decoded'
          '${malformedLen != null ? ' (last: $malformedLen bytes)' : ''}. '
          'Likely cause: a firmware/protocol mismatch.',
    FeedHealth.silent =>
      'Connected and subscribed, but no packets have arrived. '
          'Try disconnecting and reconnecting.',
    _ => 'Data is flowing normally.',
  };
}
