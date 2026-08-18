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
