import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../models/storage_capacity.dart';
import '../services/database.dart';
import '../services/storage_capacity.dart' as probe;
import '../utils/format.dart';

/// Warning for the Sessions tab shown on browsers that may delete stored
/// sessions on their own schedule — in practice the WebKit family (Safari
/// evicts after 7 days without interaction; Bluefy and the other iOS
/// browsers are WKWebView shells with undocumented storage durability).
/// Firefox is excluded: it only evicts under disk pressure, LRU-ordered.
/// Permanent and non-dismissible — the risk is ongoing, and dismissal would
/// be state to keep. Self-hides on Chromium, Firefox, and native.
class BrowserStorageWarning extends StatelessWidget {
  const BrowserStorageWarning({super.key});

  @override
  Widget build(BuildContext context) {
    if (!probe.browserMayAutoDeleteSessions()) return const SizedBox.shrink();
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

/// Fetches the platform's [StorageCapacity] and renders
/// [StorageCapacityStrip]; renders nothing where probing is unsupported
/// (desktop) or fails. Refetches on chunk-table changes — the Sessions
/// tab's refresh triggers (deletes, recording finalization, live chunk
/// writes) all land there.
class StorageCapacityLoader extends StatefulWidget {
  const StorageCapacityLoader({super.key});

  @override
  State<StorageCapacityLoader> createState() => _StorageCapacityLoaderState();
}

class _StorageCapacityLoaderState extends State<StorageCapacityLoader> {
  StorageCapacity? _capacity;
  StreamSubscription<Map<int, int>>? _cueSub;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // Errors are swallowed: on hosts without platform channels the DB never
    // opens, and the strip simply stays hidden (the smoke test pumps all
    // tabs in exactly that situation).
    _cueSub = AppDatabase.instance.watchSessionByteSizes().listen(
      (_) => unawaited(_refresh()),
      onError: (_) {},
    );
  }

  @override
  void dispose() {
    unawaited(_cueSub?.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    final capacity = await probe.fetchStorageCapacity();
    if (mounted) setState(() => _capacity = capacity);
  }

  @override
  Widget build(BuildContext context) {
    final capacity = _capacity;
    if (capacity == null) return const SizedBox.shrink();
    return StorageCapacityStrip(capacity: capacity);
  }
}

/// The capacity strip: a bar of used/(used+available), the usage/runway
/// line, and — while web storage is best-effort — the reclaim warning
/// line. Web adds the ⓘ uncertainty dialog: its numbers are quota
/// estimates, a caveat native's real free-space numbers don't need.
class StorageCapacityStrip extends StatelessWidget {
  const StorageCapacityStrip({super.key, required this.capacity});

  final StorageCapacity capacity;

  void _showEstimateDetails(BuildContext context) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('About this estimate'),
          content: const Text(
            'Based on the browser\'s reported quota. If the device\'s '
            'disk is nearly full, less space than shown may be available.'
            '\n\n'
            'When storage runs low, the browser may reclaim this space — '
            'i.e. delete recordings. Consider exporting important sessions '
            'to CSV.'
            '\n\n'
            'The native iOS and Android apps offer larger, permanent '
            'storage.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final used = formatBytes(capacity.usedBytes);
    final runway = formatRunway(capacity.recordingRunway);
    // Web's denominator is the origin quota; native has no quota, so the
    // line names free space instead.
    final usageText = kIsWeb
        ? '$used of '
              '${formatBytes(capacity.usedBytes + capacity.availableBytes)} used'
        : '$used used · ${formatBytes(capacity.availableBytes)} free';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: capacity.usedFraction,
                    minHeight: 4,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ),
              if (kIsWeb) ...[
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.info_outline, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showEstimateDetails(context),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$usageText · $runway of recording left',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
          ),
          if (!capacity.isPersistent)
            Text(
              'The browser may reclaim this space when storage runs low. '
              'The native iOS and Android apps have larger, permanent '
              'storage.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.error,
              ),
            ),
        ],
      ),
    );
  }
}
