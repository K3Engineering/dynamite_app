import 'package:material_ui/material_ui.dart';

import '../models/storage_capacity.dart';
import '../utils/format.dart';

/// Warning for the Sessions tab shown on browsers that may delete stored
/// sessions on their own schedule — in practice the WebKit family (Safari
/// evicts after 7 days without interaction; Bluefy and the other iOS
/// browsers are WKWebView shells with undocumented storage durability).
/// Firefox is excluded: it only evicts under disk pressure, LRU-ordered.
/// Permanent and non-dismissible — the risk is ongoing, and dismissal would
/// be state to keep. The Sessions tab includes this only where
/// `browserMayAutoDeleteSessions()` says the browser qualifies.
class BrowserStorageWarning extends StatelessWidget {
  const BrowserStorageWarning({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'This browser may automatically delete stored sessions after '
              'a period without use (Safari removes data after 7 days). '
              'Export important sessions to CSV to keep them safe.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// The whole web storage strip: the eviction warning. Nothing quantitative
/// is shown on web — the browser's storage estimate is unusable (see
/// `storage_capacity.dart`), so this card, shown whenever
/// `navigator.storage.persisted()` is false, is all web gets.
class StorageEvictionWarning extends StatelessWidget {
  const StorageEvictionWarning({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'The browser may delete stored sessions when the device runs '
              'low on storage. Export important sessions to CSV to keep '
              'them safe.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// The native capacity strip (Android/iOS): a bar of used/(used+available)
/// and the usage/runway line.
class StorageCapacityStrip extends StatelessWidget {
  const StorageCapacityStrip({super.key, required this.capacity});

  final StorageCapacity capacity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final used = formatBytes(capacity.usedBytes);
    final runway = formatRunway(capacity.recordingRunway);
    final usageText =
        '$used used · ${formatBytes(capacity.availableBytes)} free';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: capacity.usedFraction,
              minHeight: 4,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$usageText · $runway of recording left',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
