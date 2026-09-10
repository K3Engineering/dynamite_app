import 'dart:typed_data';

import '../models/device_flash.dart';
import '../models/device_info.dart';
import '../models/device_profile.dart';
import 'adc_protocol.dart';
import 'demo_calibration.dart';
import 'demo_signal_source.dart';
import 'link_backend.dart';
import 'link_transport.dart';

/// The simulated demo device: a synthetic feed, factory calibration, and an
/// in-memory settings round trip, for running the app without hardware. It
/// implements the link manager's [LinkTransport] contract directly — so the
/// demo runs through the same connect / post-connect setup / teardown path as
/// a real BLE link — plus [LinkBackend] for the slot and name round trips.
class DemoDevice implements LinkTransport, LinkBackend {
  @override
  String get deviceId => 'demo_device';

  @override
  String get displayName => 'Demo Device';

  @override
  bool get isSimulated => true;

  /// The demo's identity (real links read theirs from the Device Information
  /// service in post-connect setup).
  final DeviceInfo identity = const DeviceInfo(
    manufacturer: 'K3 Engineering',
    model: 'Dynamite Sampler Demo',
    serial: 'DEMO00000000',
    hardwareRev: 'demo',
    firmwareRev: 'demo',
  );

  /// The demo chain is Pro-like: AFE 101x, PGA 1x on every channel.
  final List<double> pgaGains = List.filled(kAdcChannelCount, 1.0);

  /// The demo feed's rate — its analogue of the config readback's sample
  /// rate on real links.
  int get sampleRateHz => DemoSignalSource.sampleRateHz;

  /// The flash snapshot, mutable so "Save to device" round-trips (a
  /// reconnect serves whatever was last written). Writes hit the slot keys
  /// only — mirroring the real transport, the demo's board half is
  /// read-only to the app.
  KvsSnapshot _kvs = demoKvs;

  /// The demo's stored name — the same round-trip rationale as [_kvs].
  String? _storedName;

  DemoSignalSource? _source;
  void Function(Uint8List data)? _sink;

  // -- LinkTransport ----------------------------------------------------------

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<int?> negotiateMtu() async => null;

  @override
  Future<void> discoverServices() async {}

  @override
  Future<DeviceInfo?> readDeviceInfo() async => identity;

  @override
  Future<AdcConfig> readAdcConfig() async =>
      (pgaGains: pgaGains, sampleRateHz: sampleRateHz);

  @override
  Future<void> openBackend() async {}

  @override
  LinkBackend get backend => this;

  @override
  Future<void> subscribeToAdcFeed() async {
    final sink = _sink;
    assert(
      sink != null,
      'the manager must attach a feed sink before subscribing',
    );
    (_source ??= DemoSignalSource()).start(sink!);
  }

  @override
  Future<void> unsubscribeFromAdcFeed() async => _source?.stop();

  /// The demo has no radio to read a signal strength from; the manager never
  /// calls this (see [isSimulated]).
  @override
  Future<int> readRssi() =>
      throw StateError('RSSI is not available on the demo device');

  @override
  void attachFeedSink(void Function(Uint8List data) sink) => _sink = sink;

  @override
  void dispose() => _source?.stop();

  // -- LinkBackend ------------------------------------------------------------

  @override
  Future<void> writeSlots(Map<String, String> lcKeys) async {
    _kvs = _kvs.withUserSlots(lcKeys);
  }

  @override
  Future<KvsSnapshot> readKvsSnapshot() async => _kvs;

  @override
  Future<bool> storeDeviceName(String? name) async {
    _storedName = name;
    return true;
  }

  @override
  Future<String?> readDeviceName() async => _storedName;

  /// The demo has no GATT notification path; a routed frame here means the
  /// manager's routing itself is broken.
  @override
  void handleKvsFrame(Uint8List data) =>
      throw StateError('KVS frame routed to the demo device');
}
