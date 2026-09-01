import 'dart:async';

import 'package:flutter/foundation.dart';

/// The wire-facing half of the OPFS sink worker, narrow enough to fake in
/// tests: dart:js_interop on the web build, a scripted double under the VM.
abstract interface class SinkWorkerHandle {
  /// One call per ack the worker posts. Acks never arrive unless a request
  /// was posted, and out-of-order/unknown seqs are ignored by the transport.
  set onMessage(void Function(SinkWorkerAck ack) listener);

  /// The worker's error event: the browser killed it or it never started.
  set onError(void Function() listener);

  /// Hand [request] to the worker. Byte payloads travel as transferables on
  /// web (zero-copy); detaching is fine because the writer never re-reads
  /// handed-off bytes.
  void post(SinkWorkerRequest request);

  /// Kill the worker. Called on latch and on hot-restart cleanup.
  void terminate();
}

/// One request to the worker: the named op with its scalar params and byte
/// payloads (see the op table in sink_worker.js).
final class SinkWorkerRequest {
  const SinkWorkerRequest({
    required this.seq,
    required this.op,
    this.id,
    this.intParam,
    this.bytes,
    this.bytes2,
  });

  final int seq;
  final String op;
  final String? id;
  final int? intParam;
  final Uint8List? bytes;
  final Uint8List? bytes2;
}

/// One ack from the worker: success (scalar result or a bytes payload) or an
/// op error. An op error fails that request only; it is not the worker dying.
final class SinkWorkerAck {
  const SinkWorkerAck.ok(this.seq, {this.result, this.bytes}) : error = null;
  const SinkWorkerAck.opError(this.seq, this.error)
    : result = null,
      bytes = null;

  final int seq;

  /// int, bool, or a string list depending on the op; null when the op
  /// returns nothing.
  final Object? result;
  final Uint8List? bytes;
  final String? error;
}

/// The page side of the sink worker: request/ack plumbing with one request
/// in flight (the worker relies on that for op-level isolation), a coarse
/// per-request timeout, and a single latched-fatal error model. Once latched
/// (timeout, worker error event) the transport is dead: the worker is
/// terminated and every pending and future request fails with the same error
/// — a wedged or dead sink never silently recovers.
class SinkWorkerTransport {
  SinkWorkerTransport(this._handle, {Duration? requestTimeout})
    : _requestTimeout = requestTimeout ?? const Duration(seconds: 30) {
    _live = this;
    _handle.onMessage = _onAck;
    _handle.onError = () =>
        _latch(StateError('sink worker failed to start or died (error event)'));
  }

  /// The live transport for the hot-restart cleanup hook: the web build's
  /// generation must terminate the old generation's worker before the new
  /// one opens the same session files (a sync access handle is an exclusive
  /// lock).
  static SinkWorkerTransport? _live;

  /// Terminate the live transport's worker, if any. No-op on native builds
  /// and when no transport was ever started.
  static void terminateLive() => _live?.terminate();

  final SinkWorkerHandle _handle;
  final Duration _requestTimeout;
  int _seq = 0;
  final Map<int, Completer<SinkWorkerAck>> _pending = {};
  Future<void> _chain = Future.value();
  Object? _fatal;

  /// Serializes requests: the worker's protocol is one request in flight. A
  /// failed request (latched errors included) does not poison the chain —
  /// the chain itself never carries errors forward, [_fatal] does.
  Future<SinkWorkerAck> request(
    String op, {
    String? id,
    int? intParam,
    Uint8List? bytes,
    Uint8List? bytes2,
  }) {
    final next = _chain.then((_) => _post(op, id, intParam, bytes, bytes2));
    // void-typed so a failed request's onError (returning nothing) is a
    // legal handler result: the chain swallows errors instead of carrying
    // a poisoned future into every subsequent request.
    _chain = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<SinkWorkerAck> _post(
    String op,
    String? id,
    int? intParam,
    Uint8List? bytes,
    Uint8List? bytes2,
  ) {
    final fatal = _fatal;
    if (fatal != null) return Future.error(fatal);
    final seq = _seq++;
    final completer = Completer<SinkWorkerAck>();
    _pending[seq] = completer;
    final timer = Timer(
      _requestTimeout,
      () => _latch(StateError('sink worker request "$op" timed out')),
    );
    try {
      _handle.post(
        SinkWorkerRequest(
          seq: seq,
          op: op,
          id: id,
          intParam: intParam,
          bytes: bytes,
          bytes2: bytes2,
        ),
      );
    } catch (e) {
      _pending.remove(seq);
      timer.cancel();
      return Future.error(e);
    }
    return completer.future.whenComplete(timer.cancel);
  }

  void _onAck(SinkWorkerAck ack) {
    final completer = _pending.remove(ack.seq);
    if (completer == null) return;
    final error = ack.error;
    if (error == null) {
      completer.complete(ack);
    } else {
      completer.completeError(StateError('sink worker: $error'));
    }
  }

  void _latch(Object error) {
    _fatal ??= error;
    terminate();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  void terminate() {
    try {
      if (_live == this) _live = null;
      _handle.terminate();
    } catch (_) {
      debugPrint('Session sink worker terminate failed: $_fatal');
    }
  }
}
