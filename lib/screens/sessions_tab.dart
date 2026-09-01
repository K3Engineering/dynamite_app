import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../models/damaged_session.dart';
import '../models/session_catalog.dart';
import '../models/session_summary.dart';
import '../services/export_delivery.dart';
import '../services/session_queries.dart';
import '../services/storage_probe.dart';
import '../utils/format.dart';
import '../widgets/session_flows.dart';
import '../widgets/empty_placeholder.dart';
import '../widgets/snackbars.dart';
import '../widgets/storage_capacity_strip.dart';
import '../widgets/wide_layout.dart';
import 'session_detail_screen.dart';

class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  late final ValueListenable<SessionCatalogState> _catalog =
      sessionCatalogState();

  /// The platform's storage facts for the capacity strip; null where probing
  /// is unsupported (desktop) or failed — the strip hides then.
  StorageCapacity? _capacity;
  StreamSubscription<void>? _capacityCueSub;
  bool _capacityDirty = false;
  bool _refreshingCapacity = false;

  @override
  void initState() {
    super.initState();
    unawaited(ensureSessionCatalogLoaded().catchError((_) {}));
    _requestCapacityRefresh();
    // The liveness cue rides the recording's append acks (during a
    // recording, sizes only exist in the store, not on the listing), plus
    // every mutation. Errors are swallowed: on hosts without platform
    // channels the store never opens, and the strip simply stays hidden
    // (the smoke test pumps all tabs in exactly that situation).
    _capacityCueSub = sessionByteChanges().listen(
      (_) => _requestCapacityRefresh(),
      onError: (_) {},
    );
  }

  @override
  void dispose() {
    unawaited(_capacityCueSub?.cancel());
    super.dispose();
  }

  void _requestCapacityRefresh() {
    _capacityDirty = true;
    if (!_refreshingCapacity) unawaited(_refreshCapacity());
  }

  Future<void> _refreshCapacity() async {
    _refreshingCapacity = true;
    try {
      while (_capacityDirty && mounted) {
        _capacityDirty = false;
        final capacity = await fetchStorageCapacity(
          usedBytes: sessionsUsedBytes,
        );
        if (mounted) setState(() => _capacity = capacity);
      }
    } finally {
      _refreshingCapacity = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          TabContentColumn(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Text(
                    'Sessions',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
          if (browserMayAutoDeleteSessions())
            const TabContentColumn(child: BrowserStorageWarning()),
          if (_capacity case final capacity?)
            TabContentColumn(child: StorageCapacityStrip(capacity: capacity)),
          Expanded(
            child: ValueListenableBuilder<SessionCatalogState>(
              valueListenable: _catalog,
              builder: (context, state, _) => switch (state) {
                SessionCatalogLoading() => const Center(
                  child: CircularProgressIndicator(),
                ),
                SessionCatalogFailed(:final error) => EmptyPlaceholder(
                  icon: Icons.error_outline,
                  title: 'Error loading sessions',
                  hint: '$error',
                  color: Theme.of(context).colorScheme.error,
                ),
                SessionCatalogReady(:final catalog) => _buildCatalog(catalog),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCatalog(SessionCatalog catalog) {
    final sessions = catalog.sessions;
    final damaged = catalog.damaged;
    if (sessions.isEmpty && damaged.isEmpty) {
      return const EmptyPlaceholder(
        icon: Icons.folder_open,
        title: 'No recorded sessions yet',
        hint: 'Start a recording from the Live tab',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => ListView.builder(
        padding: EdgeInsets.symmetric(
          horizontal: contentSideInset(constraints.maxWidth),
        ),
        itemCount: damaged.length + sessions.length,
        itemBuilder: (context, index) => index < damaged.length
            ? _DamagedCard(
                damaged: damaged[index],
                onExportSamples: damaged[index].hasData
                    ? () => _exportDamaged(damaged[index], data: true)
                    : null,
                onExportMetadata: damaged[index].hasMeta
                    ? () => _exportDamaged(damaged[index], data: false)
                    : null,
                onDelete: () =>
                    _deleteSession(damaged[index].id, damaged[index].id),
              )
            : _SessionCard(
                session: sessions[index - damaged.length],
                byteSize:
                    catalog.byteSizes[sessions[index - damaged.length].id],
                onTap: () => _openDetail(sessions[index - damaged.length]),
                onDelete: () => _deleteSession(
                  sessions[index - damaged.length].id,
                  sessions[index - damaged.length].name,
                ),
              ),
      ),
    );
  }

  Future<void> _openDetail(SessionSummary session) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SessionDetailScreen(session: session),
      ),
    );
  }

  Future<void> _deleteSession(String id, String name) async {
    try {
      await deleteSessionFlow(context, sessionId: id, name: name);
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(
          ScaffoldMessenger.of(context),
          'Failed to delete session: $e',
        );
      }
    }
  }

  /// Hand a damaged entry's surviving bytes to the user, verbatim, named
  /// from the directory id.
  Future<void> _exportDamaged(
    DamagedSession damaged, {
    required bool data,
  }) async {
    final fileName = '${damaged.id}.${data ? 'data.raw' : 'meta'}';
    final dialogTitle = data ? 'Export samples (raw)' : 'Export metadata (raw)';
    String? message;
    Object? error;
    try {
      message = await downloadExport(
        bytes: data
            ? await damagedDataBytes(damaged.id)
            : await damagedMetadataBytes(damaged.id),
        fileName: fileName,
        dialogTitle: dialogTitle,
      );
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    if (error != null) {
      showErrorSnackBar(
        ScaffoldMessenger.of(context),
        '$dialogTitle failed: $error',
      );
    } else if (message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.byteSize,
    required this.onTap,
    required this.onDelete,
  });

  final SessionSummary session;

  /// Exact data bytes, null until the sizes stream lands. Null simply
  /// omits the size from the subtitle.
  final int? byteSize;
  final VoidCallback onTap;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final duration = Duration(milliseconds: session.durationMs);
    final durationStr = formatDuration(duration);
    final sizeStr = byteSize != null ? ' · ${formatBytes(byteSize!)}' : '';

    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Theme.of(context).colorScheme.error,
        child: Icon(Icons.delete, color: Theme.of(context).colorScheme.onError),
      ),
      confirmDismiss: (_) async {
        await onDelete();
        return false; // We handle deletion ourselves
      },
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          onTap: onTap,
          title: Text(
            session.name.isEmpty ? untitledSessionName : session.name,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          // No peak value here: peaks are per-channel (see the detail view);
          // the stored row-wide peak is a max over all channels and reads
          // inconsistent next to them.
          subtitle: Text(
            '${formatTimestamp(session.createdAt)} · $durationStr · '
            '${session.channelCount} ch$sizeStr',
          ),
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }
}

/// The one damaged-entry surface: what the directory is, why the store
/// can't load it, and the manual affordances its bytes still afford
/// (raw exports whenever the file has any, delete behind confirmation).
class _DamagedCard extends StatelessWidget {
  const _DamagedCard({
    required this.damaged,
    required this.onExportSamples,
    required this.onExportMetadata,
    required this.onDelete,
  });

  final DamagedSession damaged;
  final VoidCallback? onExportSamples;
  final VoidCallback? onExportMetadata;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.warning_amber,
                  color: Theme.of(context).colorScheme.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Damaged session',
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  color: Theme.of(context).colorScheme.error,
                  onPressed: () => unawaited(onDelete()),
                ),
              ],
            ),
            Text(
              '${damaged.reason} · ${damaged.id}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                if (onExportSamples != null)
                  TextButton(
                    onPressed: onExportSamples,
                    child: const Text('Export samples (raw)'),
                  ),
                if (onExportMetadata != null)
                  TextButton(
                    onPressed: onExportMetadata,
                    child: const Text('Export metadata (raw)'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
