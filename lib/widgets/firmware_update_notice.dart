import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/firmware_update_service.dart';

/// The "firmware update available" line, shown on the two dark
/// `primaryContainer` device surfaces: the Live status bar and the connected
/// Devices row. Represents [FirmwareUpdateService.checkState] directly — it
/// renders nothing unless the connected device's release check found a
/// difference, so it appears and disappears with the state (no dismissal, no
/// one-shot event).
///
/// [onReview] opens the update screen. The target tag comes from the check, so
/// the line reads "Firmware update available · v1.2.3".
class FirmwareUpdateNotice extends StatelessWidget {
  const FirmwareUpdateNotice({super.key, required this.onReview});

  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final tag = context.select<FirmwareUpdateService, String?>((service) {
      final state = service.checkState;
      return state is CheckOk && state.result.differsFromDevice
          ? state.result.target!.tag
          : null;
    });
    if (tag == null) return const SizedBox.shrink();
    // inversePrimary is this app's accent-on-dark-container role (also the
    // snackbar action color); see main.dart.
    final accent = Theme.of(context).colorScheme.inversePrimary;
    return Semantics(
      button: true,
      label: 'Firmware update available',
      hint: 'Double-tap to review',
      child: GestureDetector(
        onTap: onReview,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.system_update_alt, size: 14, color: accent),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'Firmware update available · $tag',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: accent, fontSize: 12),
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: accent),
          ],
        ),
      ),
    );
  }
}
