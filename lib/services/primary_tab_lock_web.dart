/// Web implementation of the primary-tab gate.
///
/// Exactly one browser tab runs the app at a time. The gate is a single
/// blocking request to the Web Locks API — exclusive mode, deliberately NO
/// `ifAvailable`: the request resolves only once this tab holds the lock,
/// so the browser's lock manager is the queue and a losing tab simply never
/// gets past the startup overlay. Locks are bound to the browsing context
/// and auto-release on tab close AND crash, so a dead holder can never
/// leave the app locked out — no heartbeats, no stale tags to clean up.
///
/// Once granted, the lock is held for the tab's lifetime by a promise that
/// never settles. The only release path is aborting the request, which
/// exists for dev hot restart: the dying generation must let go before the
/// new generation re-requests the same lock from the same browsing context,
/// or it would block on itself. Aborting covers both states (a queued
/// request is dropped; a held lock is released), which is why there is no
/// separate release mechanism.
///
/// No take-over, steal, or demotion by design: without steal the lock can
/// never be lost while the tab lives, so there is no runtime role change to
/// guard against.
library;

import 'dart:async';

import 'dart:js_interop';

import 'package:flutter/foundation.dart';

@JS('navigator')
external _WebNavigator get _navigator;

extension type _WebNavigator(JSObject _) implements JSObject {
  external _LockManager? get locks;
}

extension type _LockManager(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(
    JSString name,
    _LockRequestOptions options,
    JSFunction callback,
  );
}

extension type _LockRequestOptions._(JSObject _) implements JSObject {
  external factory _LockRequestOptions({JSString mode, JSObject signal});
}

@JS('AbortController')
extension type _AbortController._(JSObject _) implements JSObject {
  external factory _AbortController();
  external JSObject get signal;
  external void abort();
}

Future<void>? _acquisition;
_AbortController? _currentRequest;

/// Resolves once this tab holds the primary lock. Blocks (by design) for as
/// long as another tab holds it; the caller shows the waiting overlay until
/// then and starts nothing. No Web Locks API -> always-primary: an
/// incapable browser is then exactly as ungated as it always was.
Future<void> acquirePrimaryTabLock() => _acquisition ??= _acquire();

/// Abort the in-flight request, releasing a held lock or dropping a queued
/// one. Called by the previous hot-restart generation's cleanup so the new
/// generation can take the lock in the same browsing context.
void releasePrimaryTabLock() {
  _currentRequest?.abort();
  _currentRequest = null;
}

Future<void> _acquire() {
  final locks = _navigator.locks;
  if (locks == null) return Future.value();
  final granted = Completer<void>();
  final abort = _AbortController();
  _currentRequest = abort;
  unawaited(
    locks
        .request(
          'dynamite_app'.toJS,
          _LockRequestOptions(mode: 'exclusive'.toJS, signal: abort.signal),
          (JSAny? _) {
            // Granted: this tab is primary until it dies. Hold the lock by
            // returning a promise that never settles.
            granted.complete();
            return JSPromise<JSAny?>(((JSFunction _, JSFunction _) {}).toJS);
          }.toJS,
        )
        .toDart
        .then<void>(
          (_) {},
          onError: (Object e) {
            // The hot-restart abort is the expected rejection (and that
            // generation is gone anyway). Anything else means the lock can
            // never be granted: leave the waiting overlay up and say why.
            debugPrint('primary-tab lock request failed: $e');
          },
        ),
  );
  return granted.future;
}
