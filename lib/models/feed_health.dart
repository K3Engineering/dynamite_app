/// Measured health of the ADC feed: not "subscribed" (the link state's
/// meaning) but "bytes are actually arriving and decodable". Derived live
/// from stream measurements by [deriveFeedHealth] — nothing is stored or
/// latched, so the classification can never disagree with the traffic it
/// describes, and recovery needs no reset (the next evaluation flips it).
library;

enum FeedHealth {
  /// The stream just started; its first packet is still due (within the
  /// freshness window of the stream's start stamp).
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
  silent;

  /// Nothing decodable is arriving right now: the live UI grays its readings
  /// and the rate label reads "no data"; recording refuses to start here.
  bool get noDataFlowing =>
      this == FeedHealth.stopped ||
      this == FeedHealth.blocked ||
      this == FeedHealth.silent;
}

/// Classify the feed from stream measurements (the live source is DataHub;
/// the values are passed rather than the hub so the classification stays a
/// pure function). [streaming] is the link's "ADC feed subscribed" state;
/// the health is undefined otherwise, so the function returns null.
/// [staleAfter] is the freshness window: packets normally arrive at 50 Hz,
/// so 2 s without one is never a scheduling hiccup.
FeedHealth? deriveFeedHealth({
  required bool streaming,
  required int totalSamples,
  DateTime? lastDataAt,
  DateTime? lastMalformedPacketAt,
  DateTime? streamStartedAt,
  DateTime? now,
  Duration staleAfter = const Duration(seconds: 2),
}) {
  if (!streaming) return null;
  final t = now ?? DateTime.now();
  bool fresh(DateTime? at) => at != null && t.difference(at) < staleAfter;

  if (fresh(lastDataAt)) {
    return fresh(lastMalformedPacketAt)
        ? FeedHealth.degraded
        : FeedHealth.flowing;
  }
  if (totalSamples > 0) return FeedHealth.stopped;
  if (fresh(lastMalformedPacketAt)) return FeedHealth.blocked;
  return fresh(streamStartedAt) ? FeedHealth.starting : FeedHealth.silent;
}
