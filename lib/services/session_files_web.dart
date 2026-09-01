import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';

import 'session_store_backend.dart';

/// OPFS implementation of the file layout (see SessionFilesBackend), driven
/// through `sink_worker.js`: sync access handles are worker-only APIs and the
/// worker's flush() returning is the durability boundary, so every op is one
/// request/ack pair there. The worker is transport-only — journal format,
/// recovery, damaged verdicts and id rules all live in the store.
Future<SessionFilesBackend> createBackend() async {
  final transport = _SinkWorkerTransport.start('sink_worker.js');
  // The startup probe runs from the worker because a page-side probe proves
  // nothing about the sync handles this store is built on. A browser that
  // can't pass it can't record — fail creation and let the failure surface
  // through the store's existing error paths.
  try {
    await transport.request('probe');
  } catch (e) {
    transport.terminate();
    throw StateError(
      "this browser's storage cannot safely record sessions (probe: $e)",
    );
  }
  // The replaced SQLite store's OPFS files are pre-release litter with no
  // migration story; a failure leaves harmless waste, not a broken store.
  await transport.request('dropLegacyDb');
  return _WebSessionFilesBackend(transport);
}

/// Debug-only hot-restart hook: a sync access handle holds an exclusive lock,
/// so the old generation's worker must die before the new generation's worker
/// touches the same session files (only relevant mid-recording).
void terminateSinkWorker() => _SinkWorkerTransport._live?.terminate();

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external _Worker(String scriptURL);
  external void postMessage(JSAny? message, [JSArray<JSAny>? transfer]);
  external void addEventListener(String type, JSFunction listener);
  external void terminate();
}

extension type _MessageEvent._(JSObject _) implements JSObject {
  /// The message payload; typed as [_Ack] because the sink worker's only
  /// outbound traffic is acks.
  external _Ack? get data;
}

/// The worker ack envelope ({seq, ok, result, bytes} | {seq, ok, error}).
extension type _Ack._(JSObject _) implements JSObject {
  external JSNumber? get seq;
  external JSBoolean? get ok;
  external JSAny? get result;
  external JSString? get error;
  external JSArrayBuffer? get bytes;
}

const _msgEventName =
    'm'
    'e'
    'ss'
    'a'
    'ge';

/// Transfer lists take ArrayBuffers, not views; dart:js_interop doesn't
/// expose the underlying buffer off the view, so declare it here.
extension on JSUint8Array {
  external JSArrayBuffer get buffer;
}

extension type _Req._(JSObject _) implements JSObject {
  external _Req();
  external set seq(int value);
  external set op(String value);
  external set id(String value);
  external set intParam(int value);
  external set bytes(JSAny? value);
  external set bytes2(JSAny? value);
}

/// The page side of the sink worker: request/ack plumbing with one request
/// in flight (the worker relies on that for op-level isolation), a coarse
/// per-request timeout, and a single latched-fatal error model. Once latched
/// (timeout, worker error event, worker failure to start) the transport is
/// dead: the worker is terminated and every pending and future request fails
/// with the same error — a wedged or dead sink never silently recovers.
class _SinkWorkerTransport {
  _SinkWorkerTransport._(this._worker);

  factory _SinkWorkerTransport.start(String scriptURL) {
    final worker = _Worker(scriptURL);
    final transport = _SinkWorkerTransport._(worker);
    _live = transport;
    void onMessage(JSObject event) =>
        transport._onMessage(event as _MessageEvent);
    void onError(JSObject event) => transport._latch(
      StateError('sink worker failed to start or died (error event)'),
    );
    worker.addEventListener(_msgEventName, onMessage.toJS);
    worker.addEventListener('error', onError.toJS);
    return transport;
  }

  /// The live transport for [terminateSinkWorker]'s hot-restart hook.
  static _SinkWorkerTransport? _live;

  /// Coarse per-request ceiling, orders above any bench-observed commit time
  /// at the ceiling workload: a trip means a wedged sink, never a slow one.
  static const Duration _requestTimeout = Duration(seconds: 30);

  final _Worker _worker;
  int _seq = 0;
  final Map<int, Completer<_Ack>> _pending = {};
  Future<void> _chain = Future.value();
  Object? _fatal;

  /// Serializes requests: the worker's protocol is one request in flight. A
  /// failed request (latched errors included) does not poison the chain —
  /// the chain itself never carries errors forward, [_fatal] does.
  Future<_Ack> request(
    String op, {
    String? id,
    int? intParam,
    Uint8List? bytes,
    Uint8List? bytes2,
  }) {
    final next = _chain.then((_) => _post(op, id, intParam, bytes, bytes2));
    _chain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<_Ack> _post(
    String op,
    String? id,
    int? intParam,
    Uint8List? bytes,
    Uint8List? bytes2,
  ) {
    final fatal = _fatal;
    if (fatal != null) return Future.error(fatal);
    final seq = _seq++;
    final completer = Completer<_Ack>();
    _pending[seq] = completer;
    final req = _Req()
      ..seq = seq
      ..op = op;
    if (id != null) req.id = id;
    if (intParam != null) req.intParam = intParam;
    // Byte payloads travel as transferables (zero-copy). Detaching the
    // buffers is fine: the writer never re-reads handed-off bytes.
    final transfer = <JSAny>[];
    if (bytes != null) {
      final js = bytes.toJS;
      req.bytes = js;
      transfer.add(js.buffer);
    }
    if (bytes2 != null) {
      final js = bytes2.toJS;
      req.bytes2 = js;
      transfer.add(js.buffer);
    }
    final timer = Timer(
      _requestTimeout,
      () => _latch(StateError('sink worker request "$op" timed out')),
    );
    try {
      _worker.postMessage(req, transfer.toJS);
    } catch (e) {
      _pending.remove(seq);
      timer.cancel();
      return Future.error(e);
    }
    return completer.future.whenComplete(timer.cancel);
  }

  void _onMessage(_MessageEvent event) {
    final data = event.data;
    if (data == null) return;
    final seq = data.seq?.toDartInt;
    final completer = seq == null ? null : _pending.remove(seq);
    if (completer == null) return;
    if (data.ok?.toDart ?? false) {
      completer.complete(data);
    } else {
      completer.completeError(StateError('sink worker: ${data.error?.toDart}'));
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
      _worker.terminate();
    } catch (_) {
      debugPrint('Session sink worker terminate failed: $_fatal');
    }
  }
}

extension on _Ack {
  int get intResult => (result as JSNumber).toDartInt;
  bool get boolResult => (result as JSBoolean).toDart;
  List<String> get idListResult => [
    for (var i = 0, arr = result as JSArray; i < arr.length; i++)
      (arr[i] as JSString).toDart,
  ];

  /// The transferred byte channel; null when the op found no file.
  Uint8List? get byteResult => bytes?.toDart.asUint8List();
}

class _WebSessionFilesBackend implements SessionFilesBackend {
  _WebSessionFilesBackend(this._transport);

  final _SinkWorkerTransport _transport;

  @override
  Future<SessionDataSink> createSession(
    String id,
    Uint8List metaBytes,
    Uint8List firstData,
  ) async {
    await _transport.request(
      'createSession',
      id: id,
      bytes: metaBytes,
      bytes2: firstData,
    );
    return _WebSessionDataSink(id, _transport);
  }

  @override
  Future<List<String>> listDirIds() async =>
      (await _transport.request('listDirIds')).idListResult;

  @override
  Future<Uint8List?> readJournal(String id) async =>
      (await _transport.request('readJournal', id: id)).byteResult;

  @override
  Future<Uint8List?> readData(String id) async =>
      (await _transport.request('readData', id: id)).byteResult;

  @override
  Future<int> dataByteLength(String id) async =>
      (await _transport.request('dataByteLength', id: id)).intResult;

  @override
  Future<bool> isFinalized(String id) async =>
      (await _transport.request('isFinalized', id: id)).boolResult;

  @override
  Future<void> touchFinal(String id) =>
      _transport.request('touchFinal', id: id);

  @override
  Future<void> truncateJournal(String id, int bytes) =>
      _transport.request('truncateJournal', id: id, intParam: bytes);

  @override
  Future<void> appendJournal(String id, Uint8List bytes) =>
      _transport.request('appendJournal', id: id, bytes: bytes);

  @override
  Future<void> delete(String id) => _transport.request('delete', id: id);

  @override
  Future<int> totalBytes() async =>
      (await _transport.request('totalBytes')).intResult;
}

class _WebSessionDataSink implements SessionDataSink {
  const _WebSessionDataSink(this.id, this._transport);

  @override
  final String id;

  final _SinkWorkerTransport _transport;

  /// One packet, appended and flushed in the worker; the ack's file length
  /// is the finalize-time count check's "persisted" side.
  @override
  Future<int> append(Uint8List bytes) async =>
      (await _transport.request('append', id: id, bytes: bytes)).intResult;

  @override
  Future<void> close() => _transport.request('closeSink', id: id);
}
