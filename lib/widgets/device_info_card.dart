import 'package:material_ui/material_ui.dart';

import '../models/device_info.dart';

/// The connected sampler's static identity, read from the BLE Device
/// Information service (0x180A) once per link at connect time, plus the
/// ATT MTU negotiated on that same setup pass. Purely read-only. A null
/// [info] (the connect-time read hasn't landed yet) or a null field (that
/// read failed — the serial is always null on web, where 0x2A25 is
/// blocklisted) renders as an em dash. [mtu] is likewise dashed until
/// negotiation completes, and stays dashed on web and the demo device
/// (neither path calls requestMtu).
class DeviceInfoCard extends StatelessWidget {
  const DeviceInfoCard({super.key, required this.info, this.mtu});

  /// The connected device's identity, or null until the read completes.
  final DeviceInfo? info;

  /// Negotiated ATT MTU, or null when unread / unsupported.
  final int? mtu;

  @override
  Widget build(BuildContext context) {
    final i = info;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            _row('Model', i?.model),
            _row('Hardware', i?.hardwareRev),
            _row('Firmware', i?.firmwareRev),
            _row('Serial', i?.serial),
            _row('Manufacturer', i?.manufacturer),
            _row('ATT MTU', mtu?.toString()),
          ],
        ),
      ),
    );
  }

  /// One label/value line, matching the calibration section's detail rows; a
  /// null value shows as an em dash. The value is Flexible so long firmware
  /// strings wrap instead of overflowing the row.
  static Widget _row(String label, String? value) => Padding(
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
}
