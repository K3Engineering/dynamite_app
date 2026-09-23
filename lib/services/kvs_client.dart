import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'kvs_protocol.dart';

/// Request/response client for the device's KVS. The firmware answers each
/// command write with exactly one notification, so commands are serialized and
/// matched by echoed text (see [parseKvsResponse]). A missing answer fails
/// after [commandTimeout] — the device answers every command ('B' while
/// locked/streaming), so a timeout means the link is broken. [abort] fails all
/// pending work; the client is spent afterwards (a new link builds a new one).
class KvsClient {
  KvsClient({
    required this.write,
    this.commandTimeout = const Duration(seconds: 3),
  });

  /// One command frame: a write to the link's KVS characteristic, supplied by
  /// the link manager (which owns the platform BLE call).
  final Future<void> Function(Uint8List bytes) write;

  /// Upper bound on one command's write + response round trip; below the BLE
  /// stack's own timeout so an unanswered command fails while callers can react.
  final Duration commandTimeout;

  final ListQueue<_KvsCommand> _queue = ListQueue();
  _KvsCommand? _current;
  bool _aborted = false;

  /// The value under [key], or null when the device has no such key. 'B'/'E'
  /// answers throw, as do transport and protocol failures.
  Future<String?> get(String folder, String key) async {
    final response = await _execute(encodeKvsGet(folder, key));
    response.throwIfBusyOrError();
    return response.status == KvsStatus.ok ? response.payload : null;
  }

  /// True when the device accepted the write; 'B'/'E' answers throw.
  Future<bool> set(String folder, String key, String value) async {
    final response = await _execute(encodeKvsSet(folder, key, value));
    response.throwIfBusyOrError();
    return response.status == KvsStatus.ok;
  }

  /// True when the key existed and was deleted; 'B'/'E' answers throw.
  Future<bool> delete(String folder, String key) async {
    final response = await _execute(encodeKvsDelete(folder, key));
    response.throwIfBusyOrError();
    return response.status == KvsStatus.ok;
  }

  /// All keys in [folder] with their NVS value types, via IDX iteration. Ends
  /// at the first index the device rejects; a busy/error answer throws (a
  /// truncated listing must not pass as complete). Order is the device's
  /// storage order — arbitrary but stable within a snapshot.
  Future<Map<String, int>> listKeys(String folder) async {
    final out = <String, int>{};
    for (var i = 0; ; ++i) {
      final response = await _execute(encodeKvsIndex(folder, i));
      response.throwIfBusyOrError();
      if (response.status != KvsStatus.ok) break;
      final entry = parseKvsIndexPayload(response.payload);
      out[entry.$1] = entry.$2;
    }
    return out;
  }

  /// Entry point for KVS notifications (routed here by the link manager). A
  /// frame can only settle the live command; with no command live, a duplicate
  /// (the firmware notifies before the ATT write ack, so a frame can land while
  /// the write is still awaited), or a stale answer it is dropped —
  /// [parseKvsResponse] returns null for stale and throws only for garbage,
  /// which fails the live command.
  void handleNotification(Uint8List data) {
    final current = _current;
    if (current == null || current.completer.isCompleted) return;
    try {
      final response = parseKvsResponse(current.request, data);
      if (response == null) {
        debugPrint('Dropping stale KVS frame; live: "${current.request}"');
        return;
      }
      current.completer.complete(response);
    } on FormatException catch (e) {
      current.completer.completeError(e);
    }
  }

  /// Fail every pending and queued command (link teardown); frames that
  /// arrive afterwards hit [handleNotification]'s no-live-command drop.
  void abort() {
    _aborted = true;
    // The live command sits at the queue's head.
    final error = StateError('KVS link torn down');
    _current = null;
    for (final command in _queue) {
      if (!command.completer.isCompleted) {
        command.completer.completeError(error);
      }
    }
    _queue.clear();
  }

  Future<KvsResponse> _execute(String request) {
    final command = _KvsCommand(request);
    if (_aborted) {
      return Future.error(StateError('KVS client aborted'));
    }
    _queue.add(command);
    if (_queue.length == 1) unawaited(_pump());
    return command.completer.future;
  }

  Future<void> _pump() async {
    while (_queue.isNotEmpty) {
      final command = _queue.first;
      _current = command;
      try {
        await write(Uint8List.fromList(utf8.encode(command.request)));
        await command.completer.future.timeout(commandTimeout);
      } catch (e) {
        // The response may have landed in the write window; it's the caller's
        // completer, so only fail it when no answer did.
        if (!command.completer.isCompleted) {
          command.completer.completeError(e);
        }
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

  /// The future the caller awaits: completed by [KvsClient.handleNotification]
  /// or failed by [_pump]/[KvsClient.abort], so ordering needs no second
  /// channel.
  final Completer<KvsResponse> completer = Completer();
}
