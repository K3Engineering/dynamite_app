import '../models/board_calibration.dart';
import '../models/device_flash.dart';
import 'kvs_client.dart';
import 'kvs_protocol.dart';

/// Document-level view of the device KVS: reassembles the `key=value` flash
/// document ([DeviceFlash]) out of per-key reads, and writes documents back
/// as per-key diffs against the last-read snapshot.
///
/// This is the per-key engine behind `RigFlashTransport`'s whole-document
/// contract: `RigState` and the decoder keep working on documents and never
/// see the KVS command layer.
class KvsFlashTransport {
  KvsFlashTransport(this._client);

  final KvsClient _client;

  /// The last-read document's keys and the folder each came from, so keys
  /// the model doesn't know ([DeviceFlash.extraLines]) write back where
  /// they were found.
  final Map<String, String> _keyFolders = {};
  Map<String, String> _snapshot = const {};

  /// Read every key from the Factory and User folders and reassemble the
  /// document text. Null on transport/protocol failure (the caller treats
  /// the device as having no readable document — never a crash). A key
  /// duplicated across folders collapses to the User copy, mirroring
  /// [parseFlashKv]'s last-wins.
  Future<String?> readFlashDoc() async {
    final kv = <String, String>{};
    final folders = <String, String>{};
    try {
      for (final folder in const [kvsFolderFactory, kvsFolderUser]) {
        final keys = await _client.listKeys(folder);
        for (final key in keys.keys) {
          final value = await _client.get(folder, key);
          // A key that vanished between IDX and GET is skipped, not fatal.
          if (value == null) continue;
          kv[key] = value;
          folders[key] = folder;
        }
      }
    } catch (_) {
      return null;
    }
    _keyFolders
      ..clear()
      ..addAll(folders);
    _snapshot = kv;
    return [for (final e in kv.entries) '${e.key}=${e.value}'].join('\n');
  }

  /// Write [doc] as a per-key diff against the last-read snapshot: SET the
  /// new/changed keys, DEL the removed ones, leave untouched keys alone.
  /// Throws when the device rejects any write — the caller keeps its
  /// pending edits. Without a prior read the snapshot is empty, so every
  /// key is written.
  Future<void> writeFlashDoc(String doc) async {
    final kv = parseFlashKv(doc);
    for (final e in kv.entries) {
      if (_snapshot[e.key] == e.value) continue;
      if (!await _client.set(_folderFor(e.key), e.key, e.value)) {
        throw StateError('KVS write rejected for ${e.key}');
      }
    }
    for (final key in _snapshot.keys) {
      if (kv.containsKey(key)) continue;
      if (!await _client.delete(_folderFor(key), key)) {
        throw StateError('KVS delete rejected for $key');
      }
    }
    _keyFolders.removeWhere((key, _) => !kv.containsKey(key));
    _snapshot = kv;
  }

  String _folderFor(String key) => _keyFolders[key] ?? kvsFolderForKey(key);
}
