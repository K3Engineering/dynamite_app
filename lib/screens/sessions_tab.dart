import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/force_unit.dart';
import '../services/database.dart';
import '../utils/format.dart';
import '../widgets/dialogs.dart';
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
    final settings = context.watch<AppSettings>();

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
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 64,
                          color: Colors.red,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Error loading sessions',
                          style: TextStyle(color: Colors.red, fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${snapshot.error}',
                          style: const TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }

                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final sessions = snapshot.data ?? [];

                if (sessions.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_open, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'No recorded sessions yet',
                          style: TextStyle(color: Colors.grey, fontSize: 16),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Start a recording from the Live tab',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: sessions.length,
                  itemBuilder: (context, index) => _SessionCard(
                    session: sessions[index],
                    unit: settings.displayUnit,
                    calibrationSlope: sessions[index].calibrationSlope,
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
    if (await showDeleteConfirm(context, what: session.name)) {
      await AppDatabase.instance.deleteSession(session.id);
    }
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.unit,
    required this.calibrationSlope,
    required this.onTap,
    required this.onDelete,
  });

  final Session session;
  final ForceUnit unit;
  final double calibrationSlope;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final duration = Duration(milliseconds: session.durationMs);
    final durationStr = formatDuration(duration);
    final peakDisplay = unit.format(
      unit.fromRaw(session.peakForceRaw.toDouble(), calibrationSlope),
    );

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
        onDelete();
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
          subtitle: Text(
            '${formatDate(session.createdAt)} · $durationStr\n'
            'Peak: $peakDisplay · ${session.channelCount} ch',
          ),
          isThreeLine: true,
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }
}
