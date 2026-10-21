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

  FeedHealth? derive({required bool streaming, bool paused = false}) =>
      deriveFeedHealth(
        streaming: streaming,
        totalSamples: totalSamples,
        lastDataAt: lastDataAt,
        lastMalformedPacketAt: lastMalformedPacketAt,
        streamStartedAt: streamStartedAt,
        now: t0,
        staleAfter: window,
        paused: paused,
      );

  test('undefined (null) when the link is not streaming — even with data', () {
    totalSamples = 100;
    lastDataAt = t0;
    expect(derive(streaming: false), isNull);
  });

  test('undefined (null) while monitoring is paused — even mid-stall', () {
    totalSamples = 100;
    lastDataAt = t0.subtract(const Duration(seconds: 30));
    expect(derive(streaming: true), FeedHealth.stopped);
    // The stall is deliberate (the pause discards packets), so nothing to
    // report.
    expect(derive(streaming: true, paused: true), isNull);
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

  group('decision table (all 2^4 freshness combinations)', () {
    // Priority order in [deriveFeedHealth]: fresh lastData beats everything;
    // then "ever flowed" (totalSamples > 0); then fresh malformed; finally
    // the stream-start grace. Each row stores only the two-variable tail of
    // the expansion.
    //
    // (freshLastData, totalSamples > 0, freshMalformed, freshStreamStart)
    const table = [
      // fresh lastData: malformed recency is the whole decision.
      (true, true, true, true, FeedHealth.degraded),
      (true, true, true, false, FeedHealth.degraded),
      (true, true, false, true, FeedHealth.flowing),
      (true, true, false, false, FeedHealth.flowing),
      // Fresh lastData is possible with totalSamples == 0 too (the stamp
      // outlives a counter reset in no configuration today, but the order
      // stands regardless).
      (true, false, true, true, FeedHealth.degraded),
      (true, false, true, false, FeedHealth.degraded),
      (true, false, false, true, FeedHealth.flowing),
      (true, false, false, false, FeedHealth.flowing),
      // Stale lastData, but the stream flowed before: stopped, whatever the
      // other stamps say.
      (false, true, true, true, FeedHealth.stopped),
      (false, true, true, false, FeedHealth.stopped),
      (false, true, false, true, FeedHealth.stopped),
      (false, true, false, false, FeedHealth.stopped),
      // Never flowed: malformed now => blocked; else start grace => starting.
      (false, false, true, true, FeedHealth.blocked),
      (false, false, true, false, FeedHealth.blocked),
      (false, false, false, true, FeedHealth.starting),
      (false, false, false, false, FeedHealth.silent),
    ];

    test('streaming: the classified row matches the table', () {
      for (final (freshLast, hasSamples, freshMalformed, freshStart, expected)
          in table) {
        totalSamples = hasSamples ? 1 : 0;
        lastDataAt = freshLast
            ? t0 // age 0: unambiguously fresh (boundary pinned below)
            : t0.subtract(window * 2);
        lastMalformedPacketAt = freshMalformed ? t0 : t0.subtract(window * 2);
        streamStartedAt = freshStart ? t0 : t0.subtract(window * 2);
        expect(
          derive(streaming: true),
          expected,
          reason:
              'freshLast=$freshLast total>0=$hasSamples '
              'freshMalformed=$freshMalformed freshStart=$freshStart',
        );
      }
    });

    test('not streaming or paused: every row is null', () {
      for (final (freshLast, hasSamples, freshMalformed, freshStart, _)
          in table) {
        totalSamples = hasSamples ? 1 : 0;
        lastDataAt = freshLast ? t0 : t0.subtract(window * 2);
        lastMalformedPacketAt = freshMalformed ? t0 : t0.subtract(window * 2);
        streamStartedAt = freshStart ? t0 : t0.subtract(window * 2);
        expect(derive(streaming: false), isNull);
        expect(derive(streaming: true, paused: true), isNull);
      }
    });

    test('staleAfter boundary is strict (<, not <=) for every stamp', () {
      // Exactly staleAfter old counts as STALE; one microsecond less is FRESH.
      // lastData drives flowing -> stopped.
      totalSamples = 100;
      lastDataAt = t0.subtract(window);
      expect(derive(streaming: true), FeedHealth.stopped);
      lastDataAt = t0.subtract(window - const Duration(microseconds: 1));
      expect(derive(streaming: true), FeedHealth.flowing);

      // lastMalformedPacket drives degraded -> flowing (lastData fresh)...
      lastDataAt = t0;
      lastMalformedPacketAt = t0.subtract(window);
      expect(derive(streaming: true), FeedHealth.flowing);
      lastMalformedPacketAt = t0.subtract(
        window - const Duration(microseconds: 1),
      );
      expect(derive(streaming: true), FeedHealth.degraded);

      // ...and blocked -> silent (never flowed, no malformed)...
      totalSamples = 0;
      lastDataAt = null;
      streamStartedAt = null;
      lastMalformedPacketAt = t0.subtract(window);
      expect(derive(streaming: true), FeedHealth.silent);
      lastMalformedPacketAt = t0.subtract(
        window - const Duration(microseconds: 1),
      );
      expect(derive(streaming: true), FeedHealth.blocked);

      // ...and streamStartedAt drives starting -> silent.
      lastMalformedPacketAt = null;
      streamStartedAt = t0.subtract(window);
      expect(derive(streaming: true), FeedHealth.silent);
      streamStartedAt = t0.subtract(window - const Duration(microseconds: 1));
      expect(derive(streaming: true), FeedHealth.starting);
    });
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
