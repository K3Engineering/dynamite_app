/// Measured health of the ADC feed: whether bytes are actually arriving and
/// decodable, derived live by [deriveFeedHealth]. Nothing is stored or latched.
library;

import 'hub_event.dart';

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

  /// Nothing decodable is arriving; the live UI grays out and recording refuses
  /// to start.
  bool get noDataFlowing =>
      this == FeedHealth.stopped ||
      this == FeedHealth.blocked ||
      this == FeedHealth.silent;
}

/// The stream measurements [deriveFeedHealth] consumes, as a read port
/// implemented by `DataHub`. [totalSamples] > 0 means "ever flowed".
abstract interface class FeedHealthSource {
  int get totalSamples;
  DateTime? get lastDataAt;
  DateTime? get lastMalformedPacketAt;
  DateTime? get streamStartedAt;

  /// Subscribe/unsubscribe to lifecycle events. [HubCleared] rewrites every
  /// getter above back to "stream just started".
  void addEventListener(void Function(HubEvent) listener);
  void removeEventListener(void Function(HubEvent) listener);
}

/// Classify the feed from stream measurements (passed rather than the hub to
/// keep this pure). Null when [streaming] is false. [staleAfter] is the
/// freshness window (packets normally arrive at 50 Hz).
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
