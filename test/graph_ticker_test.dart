import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression test for "A ticker was started twice" (web-only crash in
/// `_GraphWorkspaceState._syncTicker`).
///
/// The bug: the start guard read `_ticker.isTicking`, but `Ticker.start()`
/// throws on `isActive`. On web, BLE batches are delivered as microtasks at
/// `SchedulerPhase.idle`, where `isTicking` is false (ticker.dart:151-154)
/// even for a started ticker whose `_future` is set. A second guard pass then
/// called `start()` on an already-active ticker and threw.
///
/// This test encodes the framework behavior the fix relies on: at idle phase
/// a started ticker reports `isTicking == false` but `isActive == true`, so
/// guarding on `isActive` (what `start()` actually checks) is the condition
/// that prevents the double-start.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a started ticker at idle phase is active but not ticking', () {
    var ticks = 0;
    final ticker = Ticker((_) => ticks++);
    addTearDown(ticker.dispose);

    expect(ticker.isActive, isFalse);
    expect(ticker.isTicking, isFalse);

    ticker.start();
    // At idle phase (no frame being pumped): the framework's isTicking reads
    // false while isActive is already true — the window that caused the
    // double-start when the guard used isTicking.
    expect(
      SchedulerBinding.instance.schedulerPhase,
      SchedulerPhase.idle,
      reason:
          'test must observe the ticker at idle phase, as web '
          'microtask delivery does',
    );
    expect(ticker.isActive, isTrue);
    expect(ticker.isTicking, isFalse);

    // The fix's predicate: shouldTick == isActive means "already started" ->
    // do not start again. With the old isTicking predicate this same state
    // would have read "not ticking" and started twice.
    const shouldTick = true;
    final wouldStartAgain = shouldTick != ticker.isActive; // fixed guard
    expect(wouldStartAgain, isFalse);

    ticker.stop();
    expect(ticker.isActive, isFalse);
  });
}
