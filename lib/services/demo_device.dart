import 'dart:typed_data';

import '../models/device_info.dart';
import '../models/device_profile.dart';
import 'ble_link_manager.dart' show DemoLink;
import 'demo_calibration.dart';
import 'demo_signal_source.dart';

/// The simulated demo device (see [DemoLink] for the manager's view).
/// Constructed and wired by the composition root.
class DemoDevice implements DemoLink {
  @override
  String flashDoc = demoBoardCalibrationDoc;

  @override
  String? storedName;

  @override
  final DeviceInfo deviceInfo = const DeviceInfo(
    manufacturer: 'K3 Engineering',
    model: 'Dynamite Sampler Demo',
    serial: 'DEMO00000000',
    hardwareRev: 'demo',
    firmwareRev: 'demo',
  );

  /// The demo chain is Pro-like: AFE 101x, PGA 1x on every channel.
  @override
  final List<double> pgaGains = List.filled(kAdcChannelCount, 1.0);

  DemoSignalSource? _source;

  @override
  void startFeed(void Function(Uint8List) onData) {
    (_source ??= DemoSignalSource()).start(onData);
  }

  @override
  void stopFeed() => _source?.stop();
}
