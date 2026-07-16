/// Web implementation of the hot-restart cleanup hook.
///
/// Problem: on web, a hot restart re-runs `main()` in a fresh "generation" of
/// the app, but browser-side resources registered by the previous generation —
/// in particular Web Bluetooth `characteristicvaluechanged` listeners and
/// pending timers — survive. Those stale listeners keep pumping BLE packets
/// through the OLD generation's decoder/DataHub, whose `notifyListeners()`
/// tries to schedule frames on the now-disposed engine view, producing an
/// endless storm of "Trying to render a disposed EngineFlutterView" assertions.
/// The stale GATT connection can also prevent the new generation from
/// reconnecting (a connected device may stop advertising).
///
/// Fix, layer 1 (new generation): each generation stashes a cleanup closure on
/// `globalThis`. At the very start of `main()`, the new generation invokes the
/// previous generation's closure (which still holds live references to the old
/// BLE objects) so it can silence its callbacks and disconnect, then registers
/// its own closure for the NEXT restart.
///
/// Fix, layer 2 (old generation): the view is disposed by the tooling's
/// `ext.flutter.disassemble` call BEFORE module reload even starts, so packets
/// arriving during the reload window (hundreds of ms) already assert — before
/// any new-generation code can run. No app-side hook exists for that moment
/// (the engine's `registerHotRestartListener` is `dart:_engine`-internal), so
/// [installHotRestartErrorFilter] intercepts the very first
/// "disposed EngineFlutterView" assertion via [FlutterError.onError], silences
/// the stale feed right then, and swallows the teardown spam.
///
/// Both layers are debug-only: hot restart doesn't exist in release, so we
/// keep the production `window` object and error handling untouched.
library;

import 'dart:js_interop';

import 'package:flutter/foundation.dart';

/// Property on `globalThis` holding the previous generation's cleanup closure.
@JS('__dsHotRestartCleanup')
external JSFunction? get _storedCleanup;

@JS('__dsHotRestartCleanup')
external set _storedCleanup(JSFunction? value);

/// Invoke (and clear) the cleanup left behind by the previous hot-restart
/// generation, if any. Call this first thing in `main()`.
void runPreviousHotRestartCleanup() {
  if (!kDebugMode) return;
  final JSFunction? previous = _storedCleanup;
  if (previous != null) {
    _storedCleanup = null;
    previous.callAsFunction();
  }
}

/// Register this generation's [cleanup] to be run by the NEXT generation's
/// `main()` after a hot restart. Fire-and-forget: [cleanup] should kick off
/// teardown synchronously (e.g. null out data callbacks) and may finish the
/// rest (disconnect) asynchronously.
void registerHotRestartCleanup(void Function() cleanup) {
  if (!kDebugMode) return;
  _storedCleanup = cleanup.toJS;
}

/// Filter [FlutterError.onError] so the hot-restart teardown window is silent.
///
/// When a hot restart begins, the tooling's `ext.flutter.disassemble` call
/// disposes the engine view immediately, but the OLD generation keeps running
/// until modules finish reloading. Every BLE packet in that window drives
/// `notifyListeners → markNeedsBuild → scheduleFrame → drawFrame`, which
/// asserts with "Trying to render a disposed EngineFlutterView". That
/// assertion is therefore the earliest app-observable signal that a restart
/// is in flight: on the first one we run [onViewDisposed] (which silences the
/// stale BLE feed) and swallow it — and any repeats — instead of dumping them
/// to the console. Every other error passes through to the previous handler
/// unchanged.
///
/// Narrowly scoped on purpose: debug builds only (release has no hot
/// restart), and only assertions naming `EngineFlutterView` disposal — a
/// condition a correctly running single-view app can never produce.
void installHotRestartErrorFilter(void Function() onViewDisposed) {
  if (!kDebugMode) return;
  final FlutterExceptionHandler? previousHandler = FlutterError.onError;
  bool triggered = false;
  FlutterError.onError = (FlutterErrorDetails details) {
    final Object exception = details.exception;
    if (exception is AssertionError &&
        exception.toString().contains('disposed EngineFlutterView')) {
      if (!triggered) {
        triggered = true;
        onViewDisposed();
      }
      return; // Hot-restart teardown in progress: suppress the spam.
    }
    previousHandler?.call(details);
  };
}
