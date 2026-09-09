import 'dart:typed_data';

import '../models/board_calibration.dart';
import '../models/device_info.dart';
import '../models/device_profile.dart';
import 'demo_calibration.dart';
import 'demo_signal_source.dart';
import 'link_backend.dart';

/// The simulated demo device: a synthetic feed, factory calibration, and an
/// in-memory settings round trip, for running the app without hardware.
/// Implements the manager's link-backend contract directly (see
/// [SimulatedLink]); constructed and wired by the composition root.
class DemoDevice implements SimulatedLink {
  /// The synthetic device id of the demo link (never a real BLE id).
  static const deviceId = 'demo_device';

  @override
  String get id => deviceId;

  @override
  String get displayName => 'Demo Device';

  /// The flash document, mutable so "Save to device" round-trips (a
  /// reconnect serves whatever was last written). Writes hit the slot keys
  /// only — mirroring the real transport, the demo's board half is
  /// read-only to the app.
  String _flashDoc = demoBoardCalibrationDoc;

  @override
  String get flashDoc => _flashDoc;

  /// The demo's stored name — the same round-trip rationale as [_flashDoc].
  String? _storedName;

  @override
  String? get storedName => _storedName;

  @override
  Future<void> writeSlots(Map<String, String> lcKeys) async {
    final kv = parseFlashKv(_flashDoc)
      ..removeWhere((key, _) => key.startsWith('lc'))
      ..addAll(lcKeys);
    _flashDoc = [for (final e in kv.entries) '${e.key}=${e.value}'].join('\n');
  }

  @override
  Future<String> readFlashDoc() async => _flashDoc;

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

  @override
  final DeviceInfo identity = const DeviceInfo(
    manufacturer: 'K3 Engineering',
    model: 'Dynamite Sampler Demo',
    serial: 'DEMO00000000',
    hardwareRev: 'demo',
    firmwareRev: 'demo',
  );

  /// The demo chain is Pro-like: AFE 101x, PGA 1x on every channel.
  @override
  final List<double> pgaGains = List.filled(kAdcChannelCount, 1.0);

  /// The demo feed's rate — its analogue of the config readback's sample
  /// rate on real links.
  @override
  int get sampleRateHz => DemoSignalSource.sampleRateHz;

  DemoSignalSource? _source;

  @override
  void startFeed(void Function(Uint8List) onData) {
    (_source ??= DemoSignalSource()).start(onData);
  }

  @override
  void dispose() => _source?.stop();
}
