import 'package:flutter/material.dart';

import '../services/database.dart';
import '../utils/format.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_placeholder.dart';
import 'session_detail_screen.dart';

class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  /// Created once: a fresh `watchAllSessions()` per build would make the
  /// [StreamBuilder] unsubscribe and re-run the query on every rebuild
  /// (this tab rebuilds on each shell tab switch).
  late final Stream<List<Session>> _sessions = AppDatabase.instance
      .watchAllSessions();

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
          Expanded(
            child: StreamBuilder<List<Session>>(
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

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: sessions.length,
                  itemBuilder: (context, index) => _SessionCard(
                    session: sessions[index],
                    onTap: () => _openDetail(sessions[index]),
                    onDelete: () => _deleteSession(sessions[index]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDetail(Session session) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SessionDetailScreen(session: session),
      ),
    );
  }

  Future<void> _deleteSession(Session session) async {
    try {
      await deleteSessionFlow(context, session);
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
    required this.onTap,
    required this.onDelete,
  });

  final Session session;
  final VoidCallback onTap;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final duration = Duration(milliseconds: session.durationMs);
    final durationStr = formatDuration(duration);

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
            session.name.isEmpty ? 'Untitled' : session.name,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          // No peak value here: peaks are per-channel (see the detail view);
          // the stored row-wide peak is a max over all channels and reads
          // inconsistent next to them.
          subtitle: Text(
            '${formatDate(session.createdAt)} · $durationStr · '
            '${session.channelCount} ch',
          ),
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }
}
