import 'dart:convert';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../models/device_info.dart';
import 'adc_protocol.dart';
import 'bt_device_config.dart';
import 'gatt_link_backend.dart';
import 'kvs_client.dart';
import 'link_backend.dart';
import 'ota_client.dart';

/// The platform-facing half of one link: everything [BleLinkManager] drives
/// during connect, post-connect setup, and teardown — one shape for a real BLE
/// link ([BleLinkTransport]) and the simulated demo device (`DemoDevice`). The
/// manager never branches on which kind: the differences (RSSI, lifetime
/// attestation, platform release) are declared as [isSimulated].
abstract interface class LinkTransport {
  /// The platform device id (a synthetic constant for the demo).
  String get deviceId;

  /// The advertised/human name, before any stored name lands.
  String get displayName;

  /// False only for the simulated demo device (no radio): it attests no
  /// lifetime, has no RSSI, needs no platform-level GATT release, and (on web)
  /// no reconnect-settle embargo.
  bool get isSimulated;

  /// Bring the platform link up. Completes once the GATT link is usable;
  /// throws on failure.
  Future<void> connect();

  /// Release the platform link. Best-effort — never throws.
  Future<void> disconnect();

  /// Negotiate the ATT MTU, or null when the platform/link doesn't (web, demo).
  /// Throws on failure.
  Future<int?> negotiateMtu();

  /// Discover services and locate the ADC feed. Throws when the sampler
  /// service or ADC feed characteristic is absent — an unusable link.
  Future<void> discoverServices();

  /// Read the Device Information identity. Throws on failure — firmware
  /// publishes every field, so an unreadable identity is a broken link
  /// (the setup fails), never partial data. `serial` is null on web, where
  /// 0x2A25 is GATT-blocklisted.
  Future<DeviceInfo> readDeviceInfo();

  /// Read the ADC boot config. Throws when unreadable — the conversions and
  /// the sample timeline both derive from it.
  Future<AdcConfig> readAdcConfig();

  /// Bring up the KVS channel backing [backend]. Throws on failure.
  Future<void> openBackend();

  /// The active backend, or null before [openBackend].
  LinkBackend? get backend;

  /// Subscribe to the ADC feed; throws on failure.
  Future<void> subscribeToAdcFeed();

  /// Unsubscribe from the ADC feed (the feed-maintenance pause).
  Future<void> unsubscribeFromAdcFeed();

  /// Read the live RSSI. Only called when ![isSimulated].
  Future<int> readRssi();

  /// Route one OTA control notification to the live flash session's client.
  /// Frames only arrive during [runOta]; anything else drops like any
  /// unexpected characteristic.
  void handleOtaFrame(Uint8List data);

  /// Run [body] as an OTA flash session: subscribe to the control
  /// characteristic, hand [body] a wired [OtaClient], then unwind. The ADC feed
  /// stays paused throughout (firmware rejects OTA writes while the streaming
  /// subscription holds the device lock). Throws on a transport with no OTA
  /// service (the demo).
  Future<T> runOta<T>(Future<T> Function(OtaClient client) body);

  /// Provide the sink the simulated feed pushes packets into. GATT transports
  /// ignore it — notifications arrive through the platform callback.
  void attachFeedSink(void Function(Uint8List data) sink);

  /// Release per-link resources (KVS client / feed). Idempotent.
  void dispose();
}

/// The real BLE link: every per-link platform call the manager makes, wrapped
/// in one object created per connect. It also owns the KVS channel
/// ([GattLinkBackend]) and the feed-pause hook the backend needs.
class BleLinkTransport implements LinkTransport {
  BleLinkTransport({
    required this.deviceId,
    required this.displayName,
    required this.withFeedPaused,
    required this.connectTimeout,
    required this.disconnectTimeout,
  });

  @override
  final String deviceId;

  @override
  final String displayName;

  /// Run a KVS operation with the ADC feed subscription briefly paused,
  /// supplied by the link manager (which owns the subscription).
  final Future<T> Function<T>(Future<T> Function()) withFeedPaused;

  final Duration connectTimeout;
  final Duration disconnectTimeout;

  BleService? _feedService;
  String? _feedCharacteristic;
  KvsClient? _client;
  GattLinkBackend? _backend;
  int? _mtu;
  OtaClient? _otaClient;
  void Function(Uint8List data)? _onOtaFrame;
  bool _disposed = false;

  @override
  bool get isSimulated => false;

  @override
  LinkBackend? get backend => _backend;

  @override
  Future<void> connect() =>
      UniversalBle.connect(deviceId, timeout: connectTimeout);

  @override
  Future<void> disconnect() async {
    try {
      await UniversalBle.disconnect(deviceId, timeout: disconnectTimeout);
    } catch (_) {
      // Best effort: the platform link is unwanted either way.
    }
  }

  @override
  Future<int?> negotiateMtu() async {
    if (kIsWeb) return null;
    _mtu = await UniversalBle.requestMtu(deviceId, 247);
    return _mtu;
  }

  @override
  Future<void> discoverServices() async {
    final discovered = await UniversalBle.discoverServices(deviceId);
    for (final service in discovered) {
      if (service.uuid != btServiceId) continue;
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == btChrAdcFeedId &&
            characteristic.properties.contains(CharacteristicProperty.notify)) {
          _feedService = service;
          _feedCharacteristic = characteristic.uuid;
          return;
        }
      }
    }
    throw StateError('ADC feed characteristic not found on $deviceId');
  }

  @override
  Future<DeviceInfo> readDeviceInfo() => _retryOnce(() async {
    Future<String> readString(String characteristic) async => utf8.decode(
      await UniversalBle.read(deviceId, btSvcDeviceInfo, characteristic),
    );

    return DeviceInfo(
      manufacturer: await readString(btChrDisManufacturer),
      model: await readString(btChrDisModel),
      serial: kIsWeb ? null : await readString(btChrDisSerial),
      hardwareRev: await readString(btChrDisHardwareRev),
      firmwareRev: await readString(btChrDisFirmwareRev),
    );
  });

  @override
  Future<AdcConfig> readAdcConfig() => _retryOnce(() async {
    final bytes = await UniversalBle.read(
      deviceId,
      btServiceId,
      btChrAdcConfig,
    );
    final config = parseAdcConfig(bytes);
    if (config == null) {
      throw StateError('ADC config parse failed for $deviceId');
    }
    return config;
  });

  @override
  Future<void> openBackend() => _retryOnce(() async {
    final client = KvsClient(
      write: (bytes) =>
          UniversalBle.write(deviceId, btServiceId, btChrKvs, bytes),
    );
    await UniversalBle.subscribeNotifications(deviceId, btServiceId, btChrKvs);
    if (_disposed) {
      client.abort();
      return;
    }
    _client = client;
    _backend = GattLinkBackend(client: client, withFeedPaused: withFeedPaused);
  });

  @override
  Future<void> subscribeToAdcFeed() async {
    final service = _feedService;
    final characteristic = _feedCharacteristic;
    if (service == null || characteristic == null) {
      throw StateError('ADC feed characteristic not found on $deviceId');
    }
    await UniversalBle.subscribeNotifications(
      deviceId,
      service.uuid,
      characteristic,
    );
  }

  @override
  Future<void> unsubscribeFromAdcFeed() async {
    final service = _feedService;
    final characteristic = _feedCharacteristic;
    if (service == null || characteristic == null) return;
    await UniversalBle.unsubscribe(deviceId, service.uuid, characteristic);
  }

  @override
  Future<int> readRssi() => UniversalBle.readRssi(deviceId);

  @override
  void handleOtaFrame(Uint8List data) => _onOtaFrame?.call(data);

  @override
  Future<T> runOta<T>(Future<T> Function(OtaClient client) body) async {
    await UniversalBle.subscribeNotifications(
      deviceId,
      otaServiceId,
      btChrOtaControl,
    );
    // Chunk cap mirrors the reference client (min(mtu - 3, 244)). Web never
    // reports the negotiated MTU; the platforms in use negotiate 247, so
    // fall through to the 247 -> 244 cap.
    final mtu = _mtu;
    final client = OtaClient(
      chunkSize: mtu == null ? 244 : min(mtu - 3, 244),
      writeControl: (bytes, {withoutResponse = false}) => UniversalBle.write(
        deviceId,
        otaServiceId,
        btChrOtaControl,
        bytes,
        withoutResponse: withoutResponse,
      ),
      writeData: (bytes) =>
          UniversalBle.write(deviceId, otaServiceId, btChrOtaData, bytes),
    );
    _otaClient = client;
    _onOtaFrame = client.handleNotification;
    try {
      return await withFeedPaused(() => body(client));
    } finally {
      _otaClient = null;
      _onOtaFrame = null;
      client.abort();
      try {
        await UniversalBle.unsubscribe(deviceId, otaServiceId, btChrOtaControl);
      } catch (_) {
        // Teardown hygiene only; the session already settled.
      }
    }
  }

  @override
  void attachFeedSink(void Function(Uint8List data) sink) {}

  @override
  void dispose() {
    _disposed = true;
    _client?.abort();
    _client = null;
    _backend = null;
    _otaClient?.abort();
    _otaClient = null;
    _onOtaFrame = null;
  }
}

/// One retry on failure. A transient BLE hiccup is not a broken board, so the
/// link's essential reads and channel bring-up get a second chance; a
/// persistent failure still propagates (the caller fails the connection).
Future<T> _retryOnce<T>(Future<T> Function() op) async {
  try {
    return await op();
  } catch (e) {
    debugPrint('Link transport read failed, retrying once: $e');
    return op();
  }
}
