import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/services/device_clock.dart';

/// Unit tests for the PC↔device clock sync behind
/// [GraphDataSource.projectedEndAt]. All scenarios run on an injected fake
/// clock (`nowMs`), so no real time passes.
void main() {
  var nowMs = 0.0;
  late DeviceClock clock;

  setUp(() {
    nowMs = 0;
    clock = DeviceClock(
      now: () => Duration(microseconds: (nowMs * 1000).round()),
    );
  });

  // Phase offset so the 18.75 grid doesn't align with the 20 ms device
  // period (alignment would make the "jitter" periodic and unrealistic). The
  // simulation's absolute time is `nowMs + feedBase`; in it the device's
  // true sample index is absoluteTime * (1 + skew) samples/ms at 1 kHz.
  const feedBase = 7.31;

  /// Feed [durationMs] of a device running at `1 + deviceRateSkew` times the
  /// PC clock (crystal skew), batching 20 samples per packet and shipping on
  /// a fixed 18.75 ms connection grid -- the bursty delivery pattern the fit
  /// must cancel.
  void feedBlePattern(double durationMs, {double deviceRateSkew = 0}) {
    var delivered = 0; // packets handed to observe()
    var departed = 0; // packets the device has produced
    final devicePeriodMs = 20 / (1 + deviceRateSkew);
    final end = nowMs + durationMs;
    while (nowMs < end) {
      nowMs += 1;
      final t = nowMs + feedBase;
      while ((departed + 1) * devicePeriodMs <= t) {
        departed++;
      }
      // Connection event every 18.75 ms: ship everything queued, at once.
      if (t % 18.75 < 1) {
        while (delivered < departed) {
          delivered++;
          clock.observe(delivered * 20);
        }
      }
    }
  }

  test('null before the first delivery', () {
    expect(clock.projectedEndAt(1000), isNull);
  });

  test('glides at the nominal rate before the fit is valid', () {
    clock.observe(20);
    nowMs = 20;
    clock.observe(40); // 20 ms of span: far under the fit minimum
    nowMs = 60;
    // Envelope at the nominal glide: the fresher observation wins with
    // 40 + 40 ms at the slewed rate (1 - 0.004).
    expect(clock.projectedEndAt(1000), closeTo(79.84, 1e-6));
  });

  test('fits a skewed oscillator and tracks within one slot of its lead', () {
    // Device crystal +100 ppm fast; 10 s of bursty delivery.
    feedBlePattern(10000, deviceRateSkew: 100e-6);
    final total = clock.projectedEndAt(1000)!;
    // Ground truth from the simulation's oscillator: absoluteTime * (1+skew).
    // The projection must sit BEHIND it by the delivery latency (the fit can
    // only know confirmed samples) and within one 18.75 ms connection slot
    // past a trivial margin of fit wobble.
    final truth = (nowMs + feedBase) * 1.0001;
    expect(total, inInclusiveRange(truth - 21, truth));
    // The advance rate locks to the (slewed) skewed oscillator, not the
    // nominal one: every envelope line shares one slope, so the growth over
    // any observation-free interval is exactly slew * interval, no matter
    // how the argmax moves around the ring.
    final before = clock.projectedEndAt(1000)!;
    nowMs += 1000;
    expect(clock.projectedEndAt(1000)! - before, closeTo(1000.1 * 0.996, 1));
  });

  test('a long delivery gap re-anchors on the fresh side', () {
    // 2 s of clean delivery at the nominal rate, then silence while the
    // device keeps sampling off-screen (monitoring-pause shape), then one
    // delivery whose index JUMPED (the hub timeline did not pay for the
    // discarded span in this simulation -- observe() just sees a gap).
    feedBlePattern(2000);
    const lastIndex = 2000;
    nowMs += 3000; // dead-air gap
    clock.observe(lastIndex + 20); // device time moved on, index didn't
    // Ring was cleared by the gap, so the projection is a slewed nominal
    // glide from the fresh observation -- no borrowed slope from across it.
    expect(clock.projectedEndAt(1000), closeTo(lastIndex + 20, 1e-6));
    nowMs += 10;
    expect(
      clock.projectedEndAt(1000),
      closeTo(lastIndex + 20 + 10 * 0.996, 1e-6),
    );
  });

  test('clear() forgets the fit', () {
    clock.observe(20);
    clock.clear();
    expect(clock.projectedEndAt(1000), isNull);
  });
}
