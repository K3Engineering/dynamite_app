import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/feed_health.dart';
import 'package:dynamite_app/widgets/feed_health_text.dart';

/// [deriveFeedHealth] is the UI's source of truth for "is data actually
/// flowing" — a pure function of stream measurements, so this pins every
/// branch of the classification matrix (and the presentation flags that
/// ride on it).
void main() {
  final t0 = DateTime(2026, 8, 13, 12, 0, 0);
  const window = Duration(seconds: 2);

  int totalSamples = 0;
  DateTime? lastDataAt;
  DateTime? lastMalformedPacketAt;
  DateTime? streamStartedAt;

  setUp(() {
    totalSamples = 0;
    lastDataAt = null;
    lastMalformedPacketAt = null;
    streamStartedAt = null;
  });

  FeedHealth? derive({required bool streaming}) => deriveFeedHealth(
    streaming: streaming,
    totalSamples: totalSamples,
    lastDataAt: lastDataAt,
    lastMalformedPacketAt: lastMalformedPacketAt,
    streamStartedAt: streamStartedAt,
    now: t0,
    staleAfter: window,
  );

  test('undefined (null) when the link is not streaming — even with data', () {
    totalSamples = 100;
    lastDataAt = t0;
    expect(derive(streaming: false), isNull);
  });

  test('a stream within its first freshness window is "starting"', () {
    streamStartedAt = t0.subtract(const Duration(seconds: 1));
    expect(derive(streaming: true), FeedHealth.starting);
  });

  test('a stream past the window with no packets ever is "silent"', () {
    streamStartedAt = t0.subtract(const Duration(seconds: 5));
    expect(derive(streaming: true), FeedHealth.silent);
  });

  test('only malformed packets arriving is "blocked" — even on a young '
      'stream', () {
    streamStartedAt = t0.subtract(const Duration(seconds: 5));
    lastMalformedPacketAt = t0.subtract(const Duration(milliseconds: 500));
    expect(derive(streaming: true), FeedHealth.blocked);

    // Malformed packets are positive evidence of breakage; the starting
    // grace does not apply.
    streamStartedAt = t0.subtract(const Duration(seconds: 1));
    expect(derive(streaming: true), FeedHealth.blocked);
  });

  test('fresh decodable data is "flowing"; fresh malformed too is '
      '"degraded"', () {
    totalSamples = 100;
    lastDataAt = t0.subtract(const Duration(milliseconds: 500));
    expect(derive(streaming: true), FeedHealth.flowing);

    lastMalformedPacketAt = t0.subtract(const Duration(milliseconds: 100));
    expect(derive(streaming: true), FeedHealth.degraded);

    // A stale malformed note no longer downgrades a healthy stream.
    lastMalformedPacketAt = t0.subtract(const Duration(seconds: 5));
    expect(derive(streaming: true), FeedHealth.flowing);
  });

  test('a stream that flowed then went silent is "stopped"', () {
    totalSamples = 100;
    lastDataAt = t0.subtract(const Duration(seconds: 5));
    expect(derive(streaming: true), FeedHealth.stopped);

    // A stale malformed note doesn't change that (it's history, not state).
    lastMalformedPacketAt = t0.subtract(const Duration(seconds: 6));
    expect(derive(streaming: true), FeedHealth.stopped);
  });

  test('presentation: the gray "no data" treatment and the report gate', () {
    expect(FeedHealth.starting.noDataFlowing, isFalse);
    expect(FeedHealth.flowing.noDataFlowing, isFalse);
    expect(FeedHealth.degraded.noDataFlowing, isFalse);
    expect(FeedHealth.stopped.noDataFlowing, isTrue);
    expect(FeedHealth.blocked.noDataFlowing, isTrue);
    expect(FeedHealth.silent.noDataFlowing, isTrue);

    expect(FeedHealth.starting.worthReporting, isFalse);
    expect(FeedHealth.flowing.worthReporting, isFalse);
    expect(FeedHealth.degraded.worthReporting, isTrue);

    expect(FeedHealth.starting.shortLabel, isNull);
    expect(FeedHealth.flowing.shortLabel, isNull);
    expect(FeedHealth.silent.shortLabel, isNotNull);
  });
}
