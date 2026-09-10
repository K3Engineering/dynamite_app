import 'dart:typed_data';

import '../models/device_flash.dart';
import '../models/load_cell.dart';
import 'kvs_client.dart';
import 'kvs_protocol.dart';
import 'link_backend.dart';

/// The GATT link's device-side backend: the per-link KVS channel, with the
/// firmware-lock workaround applied to flash-doc and name operations —
/// firmware rejects KVS commands while the ADC feed subscription holds the
/// device lock, so those writes pause the feed via [withFeedPaused] (the
/// resume guard lives with the feed-owner that supplies the closure).
///
/// The pause applies only while streaming; the connect-time flash read runs
/// before the feed subscription, so it passes through unchanged.
class GattLinkBackend implements LinkBackend {
  GattLinkBackend({required KvsClient client, required this.withFeedPaused})
    : _client = client,
      _transport = KvsFlashTransport(client);

  final KvsClient _client;
  final KvsFlashTransport _transport;

  /// Run a KVS operation with the ADC feed subscription briefly paused,
  /// supplied by the link manager (which owns the subscription).
  final Future<T> Function<T>(Future<T> Function()) withFeedPaused;

  @override
  Future<void> writeSlots(Map<String, String> lcKeys) =>
      withFeedPaused(() => _transport.writeSlots(lcKeys));

  @override
  Future<KvsSnapshot> readKvsSnapshot() =>
      withFeedPaused(_transport.readKvsSnapshot);

  @override
  Future<bool> storeDeviceName(String? name) => withFeedPaused(
    () => name == null
        ? _client.delete(kvsFolderSettings, kvsKeyDeviceName)
        : _client.set(kvsFolderSettings, kvsKeyDeviceName, name),
  );

  @override
  Future<String?> readDeviceName() =>
      _client.get(kvsFolderSettings, kvsKeyDeviceName);

  @override
  void handleKvsFrame(Uint8List data) => _client.handleNotification(data);

  @override
  void dispose() => _client.abort();
}

/// Document-level view of the device KVS: reassembles the `key=value` flash
/// document out of per-key reads, and writes load-cell slot keys back as
/// per-key diffs against the last-read snapshot.
///
/// This is the per-key engine behind the slot contract: `RigState` and the
/// decoder keep working on documents and slot maps and never see the KVS
/// command layer.
class KvsFlashTransport {
  KvsFlashTransport(this._client);

  final KvsClient _client;

  /// The last-read store. The write diff consults only slot keys: the app
  /// never writes anything else (see [writeSlots]).
  KvsSnapshot _snapshot = KvsSnapshot(factory: const {}, user: const {});

  /// Read every key from the Factory and User folders. Throws on
  /// transport/protocol failure: a store that can't be read completely is
  /// not the device state, so the connect-time caller fails the connection
  /// and the save-time caller fails the save — no partial snapshot ever
  /// diverges silently from the device.
  Future<KvsSnapshot> readKvsSnapshot() async {
    final factory = <String, String>{};
    final user = <String, String>{};
    for (final folder in const [kvsFolderFactory, kvsFolderUser]) {
      final target = folder == kvsFolderFactory ? factory : user;
      final keys = await _client.listKeys(folder);
      for (final key in keys.keys) {
        final value = await _client.get(folder, key);
        // A key that vanished between IDX and GET means another writer
        // mutated the store mid-read — the reassembled snapshot would not
        // be coherent, so abort loudly.
        if (value == null) {
          throw StateError('KVS key "$key" vanished mid-read in $folder');
        }
        target[key] = value;
      }
    }
    return _snapshot = KvsSnapshot(factory: factory, user: user);
  }

  /// Write the exact load-cell slot keys [lcKeys] (`lc0.cap`, ...) as a
  /// per-key diff against the last-read snapshot: SET the new/changed ones,
  /// DEL slot keys the snapshot holds but [lcKeys] doesn't, leave everything
  /// else — the board half, unknown keys — untouched. All writes go to the
  /// User folder, where the slots live; the app never writes Factory.
  /// Throws when the device rejects any write — the caller keeps its
  /// pending edits. Without a prior read the snapshot is empty, so every
  /// key is written and nothing is deleted.
  Future<void> writeSlots(Map<String, String> lcKeys) async {
    for (final key in lcKeys.keys) {
      if (!rigSlotKeys.contains(key)) {
        throw ArgumentError.value(key, 'lcKeys', 'not a slot key');
      }
    }
    final user = _snapshot.user;
    for (final e in lcKeys.entries) {
      if (user[e.key] == e.value) continue;
      if (!await _client.set(kvsFolderUser, e.key, e.value)) {
        throw StateError('KVS write rejected for ${e.key}');
      }
    }
    // Reconcile: known slot keys the snapshot holds but the save doesn't
    // are deleted (a cleared slot, an abandoned partial write, a value the
    // lenient read refused to adopt — see RigSlots.fromKv).
    for (final key in user.keys) {
      if (!rigSlotKeys.contains(key) || lcKeys.containsKey(key)) continue;
      if (!await _client.delete(kvsFolderUser, key)) {
        throw StateError('KVS delete rejected for $key');
      }
    }
    _snapshot = _snapshot.withUserSlots(lcKeys);
  }
}
