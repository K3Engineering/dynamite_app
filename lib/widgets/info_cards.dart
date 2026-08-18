import 'package:material_ui/material_ui.dart';

import '../models/device_info.dart';

/// The connected sampler's static identity, read from the BLE Device
/// Information service (0x180A) once per link at connect time. Purely
/// read-only. A null [info] (the connect-time read hasn't landed yet) or a
/// null field (that read failed — the serial is always null on web, where
/// 0x2A25 is blocklisted) renders as an em dash.
class DeviceInfoCard extends StatelessWidget {
  const DeviceInfoCard({super.key, required this.info});

  /// The connected device's identity, or null until the read completes.
  final DeviceInfo? info;

  @override
  Widget build(BuildContext context) {
    final i = info;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            _infoRow('Model', i?.model),
            _infoRow('Hardware', i?.hardwareRev),
            _infoRow('Firmware', i?.firmwareRev),
            _infoRow('Serial', i?.serial),
            _infoRow('Manufacturer', i?.manufacturer),
          ],
        ),
      ),
    );
  }
}

/// Per-link connection telemetry: negotiated ATT MTU (when the platform
/// actually returns one) and the min/max ADC-feed notification sizes seen
/// on this link. [mtu] is omitted entirely when null — web and the demo
/// device never negotiate. Packet sizes dash until the first feed packet.
class ConnectionInfoCard extends StatelessWidget {
  const ConnectionInfoCard({
    super.key,
    this.mtu,
    this.minPacketBytes,
    this.maxPacketBytes,
  });

  final int? mtu;
  final int? minPacketBytes;
  final int? maxPacketBytes;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            if (mtu != null) _infoRow('ATT MTU', '$mtu'),
            _infoRow('Min packet size', _bytes(minPacketBytes)),
            _infoRow('Max packet size', _bytes(maxPacketBytes)),
          ],
        ),
      ),
    );
  }

  static String? _bytes(int? n) => n == null ? null : '$n B';
}

/// One label/value line, shared by the cards above and matching the
/// calibration section's detail rows; a null value shows as an em dash.
/// The value is Flexible so long firmware strings wrap instead of
/// overflowing the row.
Widget _infoRow(String label, String? value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 1),
  child: Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label),
      const SizedBox(width: 16),
      Flexible(child: Text(value ?? '—', textAlign: TextAlign.end)),
    ],
  ),
);
