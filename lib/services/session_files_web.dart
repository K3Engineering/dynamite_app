import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'session_store_backend.dart';
import 'sink_worker_transport.dart';

/// OPFS implementation of the file layout (see SessionFilesBackend), driven
/// through `sink_worker.js`: sync access handles are worker-only APIs and the
/// worker's flush() returning is the durability boundary, so every op is one
/// request/ack pair there. The worker is transport-only — journal format,
/// recovery, damaged verdicts and id rules all live in the store. This file
/// is the js_interop adapter for [SinkWorkerTransport]'s pure-Dart plumbing.
Future<SessionFilesBackend> createBackend() async {
  final transport = SinkWorkerTransport(_JsSinkWorkerHandle('sink_worker.js'));
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

/// Debug-only hot-restart hook: terminate the live worker.
void terminateSinkWorker() => SinkWorkerTransport.terminateLive();

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

extension type _Req._(JSObject _) implements JSObject {
  external _Req();
  external set seq(int value);
  external set op(String value);
  external set id(String value);
  external set intParam(int value);
  external set bytes(JSAny? value);
  external set bytes2(JSAny? value);
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
    final req = _Req()
      ..seq = request.seq
      ..op = request.op;
    final id = request.id;
    if (id != null) req.id = id;
    final intParam = request.intParam;
    if (intParam != null) req.intParam = intParam;
    final transfer = <JSAny>[];
    final bytes = request.bytes;
    if (bytes != null) {
      final js = bytes.toJS;
      req.bytes = js;
      transfer.add(js.buffer);
    }
    final bytes2 = request.bytes2;
    if (bytes2 != null) {
      final js = bytes2.toJS;
      req.bytes2 = js;
      transfer.add(js.buffer);
    }
    _worker.postMessage(req, transfer.toJS);
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
  /// dataByteLength, totalBytes), bool (isFinalized), a string list
  /// (listDirIds); null for the void ops.
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

  @override
  Future<int> totalBytes() async =>
      (await _transport.request('totalBytes')).intResult;
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
