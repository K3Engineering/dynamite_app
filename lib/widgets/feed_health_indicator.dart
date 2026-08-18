import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/feed_health.dart';
import '../services/feed_health_tracker.dart';
import 'feed_health_text.dart';
import 'status_colors.dart';

/// The one-line feed-health readout ("Packets malformed…", "No data from
/// device", "Stream stopped") the Devices tab renders under the connected
/// row's subtitle. Renders nothing while the feed is healthy or the link
/// isn't streaming.
class FeedHealthIndicator extends StatelessWidget {
  const FeedHealthIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FeedHealth?>(
      valueListenable: context.read<FeedHealthTracker>().health,
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
