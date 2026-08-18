import 'dart:typed_data';

import 'kvs_client.dart';
import 'kvs_flash_transport.dart';
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
  Future<void> writeFlashDoc(String doc) =>
      withFeedPaused(() => _transport.writeFlashDoc(doc));

  @override
  Future<String?> readFlashDoc() => withFeedPaused(_transport.readFlashDoc);

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
