import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'kvs_protocol.dart';

/// Request/response client for the device's key-value store. The firmware
/// answers each command write with exactly one notification, so commands
/// are strictly serialized: [KvsClient] queues internally and matches each
/// response to its request by the echoed text (see [parseKvsResponse]).
///
/// A command whose response never arrives (the firmware drops commands
/// silently while the device is locked) fails after [commandTimeout]. All
/// pending and queued commands fail on [abort] (link teardown); the client
/// is spent afterwards — a new link builds a new client.
class KvsClient {
  KvsClient({
    required this.write,
    this.commandTimeout = const Duration(seconds: 3),
  });

  /// The transport for one command frame: a write to the link's KVS
  /// characteristic, supplied by the link manager (which owns the platform
  /// BLE call).
  final Future<void> Function(Uint8List bytes) write;

  /// Upper bound on one command's write + response round trip. Comfortably
  /// below the BLE stack's own command timeout so a silently dropped
  /// command fails fast enough for callers to react.
  final Duration commandTimeout;

  final ListQueue<_KvsCommand> _queue = ListQueue();
  _KvsCommand? _current;
  bool _aborted = false;

  /// The value stored under [key], or null when the device answered "no
  /// such key". Transport and protocol failures throw.
  Future<String?> get(String folder, String key) async {
    final response = await _execute(encodeKvsGet(folder, key));
    return response.ok ? response.payload : null;
  }

  /// True when the device accepted the write.
  Future<bool> set(String folder, String key, String value) async =>
      (await _execute(encodeKvsSet(folder, key, value))).ok;

  /// True when the key existed and was deleted.
  Future<bool> delete(String folder, String key) async =>
      (await _execute(encodeKvsDelete(folder, key))).ok;

  /// All keys in [folder] with their NVS value types, via IDX iteration
  /// (which ends at the first index the device rejects). Iteration order is
  /// the device's storage order — arbitrary, but stable within a snapshot.
  Future<Map<String, int>> listKeys(String folder) async {
    final out = <String, int>{};
    for (var i = 0; ; ++i) {
      final response = await _execute(encodeKvsIndex(folder, i));
      if (!response.ok) break;
      final entry = parseKvsIndexPayload(response.payload);
      if (entry == null) {
        throw FormatException('malformed IDX payload: "${response.payload}"');
      }
      out[entry.$1] = entry.$2;
    }
    return out;
  }

  /// Entry point for KVS notifications (routed here by the link manager).
  /// Frames arriving with no command outstanding (stale, duplicated) are
  /// dropped.
  void handleNotification(Uint8List data) {
    final current = _current;
    if (current == null) return;
    try {
      current.response.complete(parseKvsResponse(current.request, data));
    } on FormatException catch (e) {
      current.response.completeError(e);
    }
  }

  /// Fail every pending and queued command (link teardown). Known
  /// limitation: a response arriving after its command timed out can be
  /// misattributed to the next command (the echo check then fails THAT one)
  /// — acceptable, because a seconds-late frame means the link is dying
  /// anyway.
  void abort() {
    _aborted = true;
    final error = StateError('KVS link torn down');
    _current?.response.completeError(error);
    for (final command in _queue) {
      command.finishError(error);
    }
    _queue.clear();
  }

  Future<KvsResponse> _execute(String request) {
    final command = _KvsCommand(request);
    if (_aborted) {
      command.finishError(StateError('KVS client aborted'));
      return command.done;
    }
    _queue.add(command);
    if (_queue.length == 1) unawaited(_pump());
    return command.done;
  }

  Future<void> _pump() async {
    while (_queue.isNotEmpty) {
      final command = _queue.first;
      _current = command;
      try {
        await write(Uint8List.fromList(utf8.encode(command.request)));
        final response = await command.response.future.timeout(commandTimeout);
        command.finish(response);
      } catch (e) {
        command.finishError(e);
      } finally {
        _current = null;
        // [abort] may have drained the queue while this command was
        // outstanding — only dequeue if it's still there.
        if (_queue.isNotEmpty && identical(_queue.first, command)) {
          _queue.removeFirst();
        }
      }
    }
  }
}

class _KvsCommand {
  _KvsCommand(this.request);

  final String request;

  /// Completed by [KvsClient.handleNotification] with the parsed frame.
  final Completer<KvsResponse> response = Completer();
  final Completer<KvsResponse> _done = Completer();

  Future<KvsResponse> get done => _done.future;

  void finish(KvsResponse r) {
    if (!_done.isCompleted) _done.complete(r);
  }

  void finishError(Object e) {
    if (!_done.isCompleted) _done.completeError(e);
  }
}
