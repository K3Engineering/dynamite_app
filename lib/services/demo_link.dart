import 'dart:typed_data';

import '../models/device_info.dart';

/// What `BleLinkManager` needs from the demo device: a synthetic link
/// source whose flash doc and stored name round-trip exactly like real
/// hardware ("Save to device" and the name editor work on the demo). The
/// implementation (`DemoDevice`) is constructed and wired by the
/// composition root — the manager never constructs one.
abstract interface class DemoLink {
  /// The flash document, mutable so "Save to device" round-trips (a
  /// reconnect serves whatever was last written).
  String get flashDoc;
  set flashDoc(String doc);

  /// The demo's stored name — the same round-trip rationale as [flashDoc].
  String? get storedName;
  set storedName(String? name);

  /// The simulated identity (real links read theirs from the Device
  /// Information service in post-connect setup).
  DeviceInfo get deviceInfo;

  /// Per-channel PGA gains served alongside the flash doc (the analogue of
  /// the GAIN-register readback on real links).
  List<double> get pgaGains;

  /// Start/stop the simulated ADC feed, delivered like GATT notifications.
  void startFeed(void Function(Uint8List) onData);
  void stopFeed();
}
