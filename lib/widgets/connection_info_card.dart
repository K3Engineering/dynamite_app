import 'package:material_ui/material_ui.dart';

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
            if (mtu != null) _row('ATT MTU', '$mtu'),
            _row('Min packet size', _bytes(minPacketBytes)),
            _row('Max packet size', _bytes(maxPacketBytes)),
          ],
        ),
      ),
    );
  }

  static String? _bytes(int? n) => n == null ? null : '$n B';

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
