import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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
  /// A frame can only settle the live command; everything else is dropped:
  /// frames with no command live, duplicates (the firmware notifies before
  /// the ATT write response, so a frame can land while the write is still
  /// awaited), and stale answers to other — already timed-out — commands
  /// ([parseKvsResponse] returns null for those, throws only for garbage,
  /// which fails the live command).
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

  /// Completed by [KvsClient.handleNotification] with the parsed frame, or
  /// by [_pump]/[KvsClient.abort] with the failure — it's the future the
  /// caller awaits, so completion ordering needs no second channel.
  final Completer<KvsResponse> completer = Completer();
}
