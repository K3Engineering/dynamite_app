import 'package:material_ui/material_ui.dart';

import '../models/device_info.dart';
import '../utils/format.dart';

/// The connected sampler's static identity, read from the BLE Device
/// Information service (0x180A) once per link at connect time. Purely
/// read-only. The serial is always null on web (0x2A25 is blocklisted
/// there) and renders as an em dash.
class DeviceInfoCard extends StatelessWidget {
  const new({super.key, required this.info});

  final DeviceInfo info;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            infoRow('Model', info.model),
            infoRow('Hardware', info.hardwareRev),
            infoRow('Firmware', info.firmwareRev),
            infoRow('Serial', info.serial),
            infoRow('Manufacturer', info.manufacturer),
          ],
        ),
      ),
    );
  }
}

/// Connection telemetry: the wire facts (negotiated ATT MTU — when the
/// platform actually returns one; min/max ADC-feed notification sizes) and
/// the stream's live stats (uptime since stream start, RF-loss sample
/// total, the clock fit's rate deviation). [mtu] is omitted entirely when
/// null — web and the demo device never negotiate. Everything else dashes:
/// packet sizes until the first feed packet, uptime then too, the
/// deviation before the rate fit has enough deliveries or while monitoring
/// is paused.
class ConnectionInfoCard extends StatelessWidget {
  const new({
    super.key,
    this.mtu,
    this.minPacketBytes,
    this.maxPacketBytes,
    this.uptime,
    this.lostSamples,
    this.rateDeviationHz,
  });

  final int? mtu;
  final int? minPacketBytes;
  final int? maxPacketBytes;
  final Duration? uptime;
  final int? lostSamples;
  final double? rateDeviationHz;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            if (mtu != null) infoRow('ATT MTU', '$mtu'),
            infoRow('Min packet size', _bytes(minPacketBytes)),
            infoRow('Max packet size', _bytes(maxPacketBytes)),
            infoRow('Uptime', uptime == null ? null : formatDuration(uptime!)),
            infoRow(
              'Samples lost',
              lostSamples == null ? null : formatThousands(lostSamples!),
            ),
            infoRow(
              'Rate deviation',
              rateDeviationHz == null ? null : _hz(rateDeviationHz!),
            ),
          ],
        ),
      ),
    );
  }

  static String? _bytes(int? n) => n == null ? null : '$n B';

  /// Signed hundredths: crystal skew is tens of ppm (hundredths of Hz at
  /// 1 kHz), and the 5 s ring fit wobbles at roughly that scale (~±250 ppm
  /// in the staircase simulator), so the value breathes a little. Finer
  /// digits would be noise.
  static String _hz(double deviation) =>
      '${deviation >= 0 ? '+' : ''}${deviation.toStringAsFixed(2)} Hz';
}

/// One label/value line, shared by the info cards and matching the
/// calibration section's detail rows; a null value shows as an em dash.
/// The value is Flexible so long firmware strings wrap instead of
/// overflowing the row.
Widget infoRow(String label, String? value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 1),
  child: Row(
    mainAxisAlignment: .spaceBetween,
    children: [
      Text(label),
      const SizedBox(width: 16),
      Flexible(child: Text(value ?? '—', textAlign: TextAlign.end)),
    ],
  ),
);
