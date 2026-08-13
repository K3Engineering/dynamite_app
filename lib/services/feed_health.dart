import '../utils/format.dart';
import 'data_hub.dart';

/// Measured health of the ADC feed: not "subscribed" (the link state's
/// meaning) but "bytes are actually arriving and decodable". Derived live
/// from hub measurements by [deriveFeedHealth] — nothing is stored or
/// latched, so the classification can never disagree with the traffic it
/// describes, and recovery needs no reset (the next evaluation flips it).
enum FeedHealth {
  /// The stream just started; its first packet is still due (within the
  /// freshness window of [DataHub.streamStartedAt]).
  starting,

  /// Decodable packets are flowing and nothing malformed arrived recently.
  flowing,

  /// Decodable packets are flowing, but malformed packets arrived recently
  /// too.
  degraded,

  /// Packets flowed earlier in this stream, then went silent.
  stopped,

  /// No decodable packet ever, but malformed packets are arriving.
  blocked,

  /// No decodable packet ever, and nothing at all is arriving.
  silent,
}

/// Classify the feed from hub measurements. [streaming] is the link's
/// "ADC feed subscribed" state; the health is undefined otherwise, so the
/// function returns null. [staleAfter] is the freshness window: packets
/// normally arrive at 50 Hz, so 2 s without one is never a scheduling hiccup.
FeedHealth? deriveFeedHealth({
  required bool streaming,
  required DataHub hub,
  DateTime? now,
  Duration staleAfter = const Duration(seconds: 2),
}) {
  if (!streaming) return null;
  final t = now ?? DateTime.now();
  bool fresh(DateTime? at) => at != null && t.difference(at) < staleAfter;

  if (fresh(hub.lastDataAt)) {
    return fresh(hub.lastMalformedPacketAt)
        ? FeedHealth.degraded
        : FeedHealth.flowing;
  }
  if (hub.totalSamples > 0) return FeedHealth.stopped;
  if (fresh(hub.lastMalformedPacketAt)) return FeedHealth.blocked;
  return fresh(hub.streamStartedAt) ? FeedHealth.starting : FeedHealth.silent;
}

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
