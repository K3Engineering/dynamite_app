import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../models/session_summary.dart';
import '../services/session_queries.dart';
import '../services/storage_probe.dart';
import '../utils/format.dart';
import 'session_flows.dart';
import '../widgets/empty_placeholder.dart';
import '../widgets/storage_capacity_strip.dart';
import 'session_detail_screen.dart';

class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  /// Created once: a fresh `watchSessionSummaries()` per build would make
  /// the [StreamBuilder] unsubscribe and re-run the query on every rebuild
  /// (this tab rebuilds on each shell tab switch).
  late final Stream<List<SessionSummary>> _sessions = watchSessionSummaries();

  /// Per-session chunk byte sizes, same created-once rule as [_sessions].
  /// Also the capacity strip's refresh cue: everything that changes stored
  /// bytes (deletes, recording finalization, live chunk writes) lands on the
  /// chunk table this stream watches.
  late final Stream<Map<int, int>> _sizes = watchSessionByteSizes();

  /// The platform's storage facts for the capacity strip; null where probing
  /// is unsupported (desktop) or failed — the strip hides then.
  StorageCapacity? _capacity;
  StreamSubscription<Map<int, int>>? _capacityCueSub;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshCapacity());
    // Errors are swallowed: on hosts without platform channels the DB never
    // opens, and the strip simply stays hidden (the smoke test pumps all
    // tabs in exactly that situation).
    _capacityCueSub = _sizes.listen(
      (_) => unawaited(_refreshCapacity()),
      onError: (_) {},
    );
  }

  @override
  void dispose() {
    unawaited(_capacityCueSub?.cancel());
    super.dispose();
  }

  Future<void> _refreshCapacity() async {
    final capacity = await fetchStorageCapacity(
      usedBytes: sessionDatabaseFileBytes,
    );
    if (mounted) setState(() => _capacity = capacity);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
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
          if (browserMayAutoDeleteSessions()) const BrowserStorageWarning(),
          if (_capacity case final capacity?)
            StorageCapacityStrip(capacity: capacity),
          Expanded(
            child: StreamBuilder<List<SessionSummary>>(
              stream: _sessions,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return EmptyPlaceholder(
                    icon: Icons.error_outline,
                    title: 'Error loading sessions',
                    hint: '${snapshot.error}',
                    color: Theme.of(context).colorScheme.error,
                  );
                }

                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final sessions = snapshot.data ?? [];

                if (sessions.isEmpty) {
                  return const EmptyPlaceholder(
                    icon: Icons.folder_open,
                    title: 'No recorded sessions yet',
                    hint: 'Start a recording from the Live tab',
                  );
                }

                return StreamBuilder<Map<int, int>>(
                  stream: _sizes,
                  builder: (context, sizeSnapshot) {
                    final sizes = sizeSnapshot.data ?? const <int, int>{};
                    return ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: sessions.length,
                      itemBuilder: (context, index) => _SessionCard(
                        session: sessions[index],
                        byteSize: sizes[sessions[index].id],
                        onTap: () => _openDetail(sessions[index]),
                        onDelete: () => _deleteSession(sessions[index]),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
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

  Future<void> _deleteSession(SessionSummary session) async {
    try {
      await deleteSessionFlow(
        context,
        sessionId: session.id,
        name: session.name,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete session: $e')));
      }
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

  /// Exact chunk payload bytes, null until the sizes stream lands. Null
  /// simply omits the size from the subtitle.
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
