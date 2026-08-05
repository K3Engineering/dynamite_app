import 'package:flutter/material.dart';

import '../models/device_info.dart';

/// Settings → Device settings → Device info: the connected sampler's static
/// identity, read from the BLE Device Information service (0x180A) once per
/// link at connect time. Purely read-only. A null [info] (the connect-time
/// read hasn't landed yet) or a null field (that read failed — the serial is
/// always null on web, where 0x2A25 is blocklisted) renders as an em dash,
/// never as a made-up or stale value.
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
            _row('Model', i?.model),
            _row('Hardware', i?.hardwareRev),
            _row('Firmware', i?.firmwareRev),
            _row('Serial', i?.serial),
            _row('Manufacturer', i?.manufacturer),
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
