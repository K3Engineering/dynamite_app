import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'bench_spec.dart';

/// Request/reply bridge to web/bench_worker.js. One request in flight (the
/// controller serializes runs); a second concurrent request is a bug, not a
/// queue.
class BenchWorkerClient {
  web.Worker? _worker;
  Completer<Map<String, Object?>>? _pending;
  void Function(Map<String, Object?>)? _onEvent;

  web.Worker _ensure() {
    final existing = _worker;
    if (existing != null) return existing;
    final w = web.Worker('bench_worker.js'.toJS);
    w.onmessage = ((web.Event e) {
      _dispatch((e as web.MessageEvent).data);
    }).toJS;
    w.onerror = ((web.Event e) {
      _failPending(StateError('bench worker error event'));
    }).toJS;
    _worker = w;
    return w;
  }

  void _dispatch(JSAny? data) {
    final msg = (data.dartify() as Map).cast<String, Object?>();
    if (msg['type'] == 'progress') {
      _onEvent?.call(msg);
      return;
    }
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    switch (msg['type']) {
      case 'probe':
      case 'result':
        pending.complete(msg);
      case 'aborted':
        pending.completeError(const BenchAborted());
      case 'error':
        pending.completeError(StateError('bench worker: ${msg['message']}'));
      default:
        pending.completeError(StateError('unknown worker message: $msg'));
    }
  }

  void _failPending(Object error) {
    final pending = _pending;
    _pending = null;
    pending?.completeError(error);
  }

  Future<Map<String, Object?>> call(
    Map<String, Object?> request, {
    void Function(Map<String, Object?>)? onEvent,
  }) {
    if (_pending != null) throw StateError('bench worker busy');
    final completer = Completer<Map<String, Object?>>();
    _pending = completer;
    _onEvent = onEvent;
    _ensure().postMessage(request.jsify());
    return completer.future;
  }

  void abort() {
    _worker?.postMessage({'cmd': 'abort'}.jsify());
  }

  void dispose() {
    _failPending(const BenchAborted());
    _worker?.terminate();
    _worker = null;
  }
}
