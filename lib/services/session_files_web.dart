import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';

import 'session_store_backend.dart';
import 'sink_worker_transport.dart';

/// OPFS implementation of the file layout (see SessionFilesBackend), driven
/// through `sink_worker.js`: sync access handles are worker-only APIs and the
/// worker's flush() returning is the durability boundary, so every op is one
/// request/ack pair there. The worker is transport-only — journal format,
/// damaged/interrupted verdicts and id rules all live in the store. This
/// file is the js_interop adapter for [SinkWorkerTransport]'s pure-Dart
/// plumbing.

/// The live transport, referenced at the one place workers are created so
/// the hot-restart hook can kill the old generation's worker before the new
/// one opens the same session files (a sync access handle is an exclusive
/// lock).
SinkWorkerTransport? _liveTransport;

Future<SessionFilesBackend> createBackend() async {
  final transport = SinkWorkerTransport(_JsSinkWorkerHandle('sink_worker.js'));
  _liveTransport = transport;
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
  // migration story. Best-effort, as the native drop already is: litter is
  // harmless, so a sweep failure is reported but must never fail
  // construction — a bare await here would brick the whole store for the
  // app's lifetime, one op past a successful probe.
  try {
    await transport.request('dropLegacyDb');
  } catch (e) {
    debugPrint('Legacy session database drop failed: $e');
  }
  return _WebSessionFilesBackend(transport);
}

/// Debug-only hot-restart hook: terminate the live worker, if any.
void terminateSinkWorker() {
  final transport = _liveTransport;
  _liveTransport = null;
  transport?.terminate();
}

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

/// Transfer lists take ArrayBuffers, not views; dart:js_interop doesn't
/// expose the underlying buffer off the view, so declare it here.
extension on JSUint8Array {
  external JSArrayBuffer get buffer;
}

/// Object-literal constructor: a null nullable field is omitted from the
/// wire object entirely, and the worker reads absent as unset.
extension type _Req._(JSObject _) implements JSObject {
  external _Req({
    required int seq,
    required String op,
    String? id,
    int? intParam,
    JSUint8Array? bytes,
    JSUint8Array? bytes2,
  });
}

/// The JS worker behind [SinkWorkerTransport]: converts acks and requests
/// across the interop boundary and nothing else.
class _JsSinkWorkerHandle implements SinkWorkerHandle {
  _JsSinkWorkerHandle(String scriptURL) : _worker = _Worker(scriptURL) {
    void onJsMessage(JSObject event) {
      final ack = _convertAck((event as _MessageEvent).data);
      if (ack != null) _onMessage(ack);
    }

    void onJsError(JSObject _) => _onError();

    _worker.addEventListener('message', onJsMessage.toJS);
    _worker.addEventListener('error', onJsError.toJS);
  }

  final _Worker _worker;

  late void Function(SinkWorkerAck ack) _onMessage;
  late void Function() _onError;

  @override
  set onMessage(void Function(SinkWorkerAck ack) listener) =>
      _onMessage = listener;

  @override
  set onError(void Function() listener) => _onError = listener;

  @override
  void post(SinkWorkerRequest request) {
    final bytes = request.bytes?.toJS;
    final bytes2 = request.bytes2?.toJS;
    final transfer = <JSAny>[
      if (bytes != null) bytes.buffer,
      if (bytes2 != null) bytes2.buffer,
    ];
    _worker.postMessage(
      _Req(
        seq: request.seq,
        op: request.op,
        id: request.id,
        intParam: request.intParam,
        bytes: bytes,
        bytes2: bytes2,
      ),
      transfer.toJS,
    );
  }

  @override
  void terminate() => _worker.terminate();

  static SinkWorkerAck? _convertAck(_Ack? data) {
    if (data == null) return null;
    final seq = data.seq?.toDartInt;
    if (seq == null) return null;
    if (data.ok?.toDart ?? false) {
      return SinkWorkerAck.ok(
        seq,
        result: _convertResult(data.result),
        bytes: data.bytes?.toDart.asUint8List(),
      );
    }
    return SinkWorkerAck.opError(seq, '${data.error?.toDart}');
  }

  /// The ops' scalar result wire types: int (append's file length,
  /// dataByteLength), bool (isFinalized), a string list (listDirIds);
  /// null for the void ops.
  static Object? _convertResult(JSAny? result) {
    if (result == null) return null;
    if (result.typeofEquals('number')) return (result as JSNumber).toDartInt;
    if (result.typeofEquals('boolean')) return (result as JSBoolean).toDart;
    if (result.typeofEquals('object')) {
      return [
        for (var i = 0, arr = result as JSArray; i < arr.length; i++)
          (arr[i] as JSString).toDart,
      ];
    }
    return null;
  }
}

extension on SinkWorkerAck {
  int get intResult => result as int;
  bool get boolResult => result as bool;
  List<String> get idListResult => result as List<String>;

  /// The transferred byte channel; null when the op found no file.
  Uint8List? get byteResult => bytes;
}

class _WebSessionFilesBackend implements SessionFilesBackend {
  _WebSessionFilesBackend(this._transport);

  final SinkWorkerTransport _transport;

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
}

class _WebSessionDataSink implements SessionDataSink {
  const _WebSessionDataSink(this.id, this._transport);

  @override
  final String id;

  final SinkWorkerTransport _transport;

  /// One packet, appended and flushed in the worker; the ack's file length
  /// is the finalize-time count check's "persisted" side.
  @override
  Future<int> append(Uint8List bytes) async =>
      (await _transport.request('append', id: id, bytes: bytes)).intResult;

  @override
  Future<void> close() => _transport.request('closeSink', id: id);
}
