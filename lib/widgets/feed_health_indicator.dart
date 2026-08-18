import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../models/feed_health.dart';
import 'feed_health_text.dart';
import 'status_colors.dart';

/// The one-line feed-health readout ("Packets malformed…", "No data from
/// device", "Stream stopped") the Devices tab renders under the connected
/// row's subtitle. Renders nothing while the feed is healthy or the link
/// isn't streaming.
class FeedHealthIndicator extends StatelessWidget {
  const FeedHealthIndicator({super.key, required this.health});

  /// The live feed-health classification (see `FeedHealthTracker.health`).
  /// Passed in (not reached through Provider) so the indicator renders
  /// without an app-wide provider above it.
  final ValueListenable<FeedHealth?> health;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FeedHealth?>(
      valueListenable: health,
      builder: (context, health, _) {
        final label = health?.shortLabel;
        if (label == null) return const SizedBox.shrink();
        final color = Theme.of(
          context,
        ).extension<StatusColors>()!.onConnectedWarning;
        return Row(
          children: [
            Icon(Icons.error_outline, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: color),
              ),
            ),
          ],
        );
      },
    );
  }
}
